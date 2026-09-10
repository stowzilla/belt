# frozen_string_literal: true

require_relative 'env_resolver'
require_relative 'terraform_command'
require_relative '../inflector'

module Belt
  module CLI
    class TablesCommand
      MODULE_DIR = 'infrastructure/modules/app'
      MODELS_DIR = 'lambda/models'

      def self.run(args)
        # Environment argument accepted for backwards compatibility but unused —
        # dynamodb.tf lives in infrastructure/modules/app and uses var.environment.
        EnvResolver.resolve(args)

        # `--force`/`-y` overwrites dynamodb.tf even when the regen would drop a
        # hand-added table or GSI. Without it, an interactive run prompts before
        # clobbering and a quiet (generator) run refuses.
        force = args.intersect?(%w[--force -f --yes -y])

        new(force: force).run
      end

      # Automatically sync dynamodb.tf in the app module.
      # Called by generators after creating/updating model files.
      def self.sync_all_environments
        return unless Dir.exist?(MODELS_DIR)

        new(quiet: true).run
      end

      def initialize(quiet: false, force: false)
        @quiet = quiet
        @force = force
      end

      def run
        return unless validate!

        models = parse_models
        if models.empty?
          puts "No models found in #{MODELS_DIR}/" unless @quiet
          return
        end

        generate_dynamodb_tf(models)
      end

      private

      def validate!
        unless Dir.exist?(MODELS_DIR)
          unless @quiet
            abort "Error: No models directory found at #{MODELS_DIR}/. " \
                  'Run `belt generate model` to create your first model.'
          end
          return false
        end
        return true if Dir.exist?(MODULE_DIR)

        return false if @quiet

        abort "Error: Module directory not found at #{MODULE_DIR}/.\n" \
              'Run `belt new` to create a project with the correct structure.'
      end

      def parse_models
        model_files = Dir.glob(File.join(MODELS_DIR, '*.rb'))
                         .reject { |f| File.basename(f) == 'application_record.rb' }
                         .reject { |f| File.basename(f).start_with?('concerns') }
                         .sort

        model_files.filter_map { |f| parse_model_file(f) }
      end

      # Parse a model file to extract its name and index declarations.
      # Uses lightweight regex parsing — does NOT require loading activeitem or the model.
      def parse_model_file(file_path)
        content = File.read(file_path)

        # Extract class name from `class Foo < ApplicationRecord`
        class_match = content.match(/^class\s+(\w+)\s*<\s*ApplicationRecord/)
        return nil unless class_match

        class_name = class_match[1]
        model_name = Belt::Inflector.underscore(class_name)

        # Extract indexes() declaration
        indexes = extract_indexes(content)

        # cognito_authenticatable installs a GSI without an indexes() call
        indexes += extract_cognito_indexes(content)

        # Extract belongs_to associations and generate convention indexes
        indexes += extract_belongs_to_indexes(content)

        # Deduplicate by index name
        indexes.uniq! { |idx| idx[:name] }

        { name: model_name, indexes: indexes }
      end

      def extract_indexes(content)
        indexes = []

        # Match the indexes() DSL: indexes('Name' => { partition_key: 'pk' }, ...)
        # This handles the Ruby hash syntax used by ActiveItem
        index_block = content.match(/^\s*indexes\(\s*\n?(.*?)\n?\s*\)/m)
        return indexes unless index_block

        index_content = index_block[1]

        # Parse each index entry: 'IndexName' => { partition_key: 'key', sort_key: 'key' }
        index_content.scan(/'([^']+)'\s*=>\s*\{([^}]+)\}/) do |name, opts|
          partition_key = opts.match(/partition_key:\s*'([^']+)'/)&.captures&.first
          sort_key = opts.match(/sort_key:\s*'([^']+)'/)&.captures&.first
          next unless partition_key

          indexes << { name: name, partition_key: partition_key, sort_key: sort_key }
        end

        indexes
      end

      # `cognito_authenticatable` installs an EmailIndex GSI without the model ever
      # calling indexes() — see Belt::Authentication::CognitoAuthenticatable. The
      # generator has to know that, or the table would be created without the GSI and
      # the first email lookup would fail in production instead of here.
      def extract_cognito_indexes(content)
        declaration = uncommented(content).match(/^\s*cognito_authenticatable\b(.*)$/)
        return [] unless declaration

        options = declaration[1].to_s
        return [] if options.match?(/email_index:\s*false/)

        name = options.match(/email_index:\s*['"]([^'"]+)['"]/)
        [{ name: name ? name[1] : 'EmailIndex', partition_key: 'email', sort_key: nil }]
      end

      # Extract belongs_to declarations and generate convention-based GSI indexes.
      # belongs_to :conversation → ConversationIndex with partition_key: 'conversationId'
      #
      # `index: false` opts out — the model is saying the reverse lookup is covered some
      # other way (its own indexes() entry, usually, under a different key name).
      # Generating one anyway produces a GSI on an attribute that doesn't exist.
      def extract_belongs_to_indexes(content)
        indexes = []

        uncommented(content).scan(/belongs_to\s+:(\w+)([^\n]*)/) do |association_name, options|
          next if options.match?(/index:\s*false/)

          index_name = "#{Belt::Inflector.classify(association_name)}Index"
          partition_key = "#{association_name}Id"

          indexes << { name: index_name, partition_key: partition_key, sort_key: nil }
        end

        indexes
      end

      def uncommented(content)
        content.lines.reject { |line| line.strip.start_with?('#') }.join
      end

      def generate_dynamodb_tf(models)
        dest = File.join(MODULE_DIR, 'dynamodb.tf')
        existing_content = File.exist?(dest) ? File.read(dest) : nil
        new_content = render_dynamodb(models)

        # Skip if content is unchanged
        return if existing_content == new_content

        # Regenerating dynamodb.tf is a full overwrite. Anything hand-added to the
        # file that the generator can't re-derive from the models — a GSI added
        # straight into the .tf, or a table for a model that no longer exists — would
        # silently vanish. Detect that and refuse (quiet) or prompt (interactive)
        # unless --force was passed.
        if existing_content
          dropped = detect_dropped_infrastructure(existing_content, new_content)
          return if dropped.any? && !safe_to_overwrite?(dest, dropped)
        end

        File.write(dest, new_content)

        if @quiet
          verb = existing_content ? 'update' : 'create'
          puts "  #{verb}  #{dest}"
        else
          puts "  create  #{dest}"
          puts "\n✓ Generated DynamoDB tables for #{models.size} model(s):"
          models.each { |m| puts "    • #{Belt::Inflector.pluralize(m[:name])}" }
          puts "\nRun `belt deploy` to create them."
        end
      end

      # Compare the existing dynamodb.tf against the freshly rendered content and
      # return a list of human-readable descriptions of infrastructure that exists
      # today but wouldn't be regenerated — i.e. would be dropped by the overwrite.
      #
      # We only surface *removals*, since additions and edits are the whole point of
      # re-running the generator. A removal, on the other hand, is usually a mistake:
      # a GSI someone added by hand that the model doesn't declare.
      def detect_dropped_infrastructure(existing_content, new_content)
        dropped = []

        old_tables = table_labels(existing_content)
        new_tables = table_labels(new_content)
        dropped.concat((old_tables - new_tables).map { |label| "table \"#{label}\"" })

        # Only compare GSIs on tables that survive — a dropped table already
        # accounts for its indexes, no need to list them twice.
        (old_tables & new_tables).each do |label|
          old_gsis = gsi_names(existing_content, label)
          new_gsis = gsi_names(new_content, label)
          dropped.concat((old_gsis - new_gsis).map { |gsi| "GSI \"#{gsi}\" on table \"#{label}\"" })
        end

        dropped
      end

      # Resource labels for every aws_dynamodb_table block in the content.
      def table_labels(content)
        content.scan(/resource\s+"aws_dynamodb_table"\s+"([^"]+)"/).flatten
      end

      # GSI names declared inside the given table's resource block.
      def gsi_names(content, label)
        block = table_block(content, label)
        return [] unless block

        block.scan(/global_secondary_index\s*\{[^}]*?name\s*=\s*"([^"]+)"/m).flatten
      end

      # Extract the body of a single aws_dynamodb_table resource block by brace
      # matching, so we can scope GSI lookups to one table.
      def table_block(content, label)
        marker = /resource\s+"aws_dynamodb_table"\s+"#{Regexp.escape(label)}"\s*\{/
        match = content.match(marker)
        return nil unless match

        start = match.end(0)
        depth = 1
        idx = start
        while idx < content.length && depth.positive?
          case content[idx]
          when '{' then depth += 1
          when '}' then depth -= 1
          end
          idx += 1
        end
        content[start...(idx - 1)]
      end

      # Decide whether it's safe to overwrite dynamodb.tf when the regen would drop
      # hand-added infrastructure. Returns true to proceed, false to abort the write.
      def safe_to_overwrite?(dest, dropped)
        return true if @force

        warn_dropped(dest, dropped)

        # A generator auto-sync must never silently destroy custom infra. Refuse and
        # tell the user to resolve it deliberately.
        if @quiet
          puts '  ⚠ skipped dynamodb.tf — would drop hand-added infrastructure ' \
               '(run `belt setup tables` to review)'
          return false
        end

        print "\nOverwrite anyway and drop the above? [y/N] "
        response = $stdin.gets&.strip&.downcase
        return true if %w[y yes].include?(response)

        puts '✗ Aborted. dynamodb.tf left unchanged.'
        puts '  Move the custom definition into a model, or re-run with --force to overwrite.'
        false
      end

      def warn_dropped(dest, dropped)
        puts "\n⚠ Regenerating #{dest} would DROP infrastructure not derived from your models:"
        dropped.each { |d| puts "    • #{d}" }
        puts "\n  This usually means a table or GSI was added to dynamodb.tf by hand."
        puts '  Belt only tracks tables and indexes it can read from lambda/models/*.rb,'
        puts '  so a hand-added definition is invisible to the generator and gets overwritten.'
      end

      def render_dynamodb(models)
        blocks = models.map { |m| render_table(m) }
        "# Auto-generated by Belt from model definitions in lambda/models/*.rb\n" \
          "#\n" \
          "# Do NOT edit manually. `belt setup tables` overwrites this whole file from\n" \
          "# your models. Any table or GSI added here by hand (that a model doesn't\n" \
          "# declare) will be DROPPED on the next regeneration. Define indexes on the\n" \
          "# model via indexes(), belongs_to, or cognito_authenticatable instead.\n\n#{blocks.join("\n\n")}\n"
      end

      def render_table(model)
        name = table_name(model[:name])
        custom_indexes = model[:indexes] || []

        # Collect all custom index attribute names, deduplicating against built-in ones
        builtin_attrs = Set.new(%w[id _recent_pk createdAt])
        extra_attrs = []
        custom_indexes.each do |idx|
          unless builtin_attrs.include?(idx[:partition_key])
            extra_attrs << idx[:partition_key]
            builtin_attrs.add(idx[:partition_key])
          end
          if idx[:sort_key] && !builtin_attrs.include?(idx[:sort_key])
            extra_attrs << idx[:sort_key]
            builtin_attrs.add(idx[:sort_key])
          end
        end

        lines = []
        lines << "resource \"aws_dynamodb_table\" \"#{Belt::Inflector.pluralize(model[:name])}\" {"
        lines << "  name         = \"#{name}\""
        lines << '  billing_mode = "PAY_PER_REQUEST"'
        lines << '  hash_key     = "id"'
        lines << ''
        lines << '  attribute {'
        lines << '    name = "id"'
        lines << '    type = "S"'
        lines << '  }'
        lines << ''
        lines << '  attribute {'
        lines << '    name = "_recent_pk"'
        lines << '    type = "S"'
        lines << '  }'
        lines << ''
        lines << '  attribute {'
        lines << '    name = "createdAt"'
        lines << '    type = "S"'
        lines << '  }'

        extra_attrs.each do |attr|
          lines << ''
          lines << '  attribute {'
          lines << "    name = \"#{attr}\""
          lines << '    type = "S"'
          lines << '  }'
        end

        lines << ''
        lines << '  global_secondary_index {'
        lines << '    name            = "RecentIndex"'
        lines << '    hash_key        = "_recent_pk"'
        lines << '    range_key       = "createdAt"'
        lines << '    projection_type = "ALL"'
        lines << '  }'

        custom_indexes.each do |idx|
          lines << ''
          lines << '  global_secondary_index {'
          lines << "    name            = \"#{idx[:name]}\""
          lines << "    hash_key        = \"#{idx[:partition_key]}\""
          lines << "    range_key       = \"#{idx[:sort_key]}\"" if idx[:sort_key]
          lines << '    projection_type = "ALL"'
          lines << '  }'
        end

        lines << ''
        lines << '  point_in_time_recovery {'
        lines << '    enabled = var.enable_pitr'
        lines << '  }'
        lines << ''
        lines << '  deletion_protection_enabled = var.deletion_protection'
        lines << ''
        lines << '  tags = {'
        lines << "    Name        = \"#{name}\""
        lines << '    Environment = var.environment'
        lines << '    ManagedBy   = "Terraform"'
        lines << '  }'
        lines << '}'

        lines.join("\n")
      end

      def table_name(model_name)
        # Dasherize to match ActiveItem's table_name_for convention:
        # class_name.underscore.dasherize.pluralize
        "${var.app_name}-${var.environment}-#{Belt::Inflector.pluralize(model_name).tr('_', '-')}"
      end
    end
  end
end
