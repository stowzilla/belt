# frozen_string_literal: true

require_relative 'tables_command'
require_relative '../inflector'

module Belt
  module CLI
    class IndexCommand
      MODULE_DIR = 'infrastructure/modules/app'
      DYNAMODB_TF = File.join(MODULE_DIR, 'dynamodb.tf')

      def self.run(args)
        action = args.shift

        case action
        when 'add', nil
          add(args)
        when 'remove', 'rm'
          remove(args)
        when '--help', '-h'
          puts usage
        else
          # Treat first arg as table name if no subcommand
          add([action] + args)
        end
      end

      def self.usage
        <<~USAGE
          Usage: belt generate index <table> <IndexName> --partition-key <key> [--sort-key <key>]
                 belt destroy index <table> <IndexName>

          Add or remove a Global Secondary Index (GSI) from dynamodb.tf.

          Examples:
            belt generate index messages ConversationIndex --partition-key conversation_id
            belt generate index messages RecentByUserIndex --partition-key user_id --sort-key created_at
            belt destroy index messages ConversationIndex

          Note: After modifying indexes, run `belt deploy` to apply changes to AWS.
                Adding a GSI to an existing table takes ~5-10 minutes (AWS limitation).
        USAGE
      end

      def self.add(args)
        table, index_name, partition_key, sort_key = parse_add_args(args)
        new(table, index_name, partition_key: partition_key, sort_key: sort_key).add
      end

      def self.remove(args)
        table = args.shift
        index_name = args.shift

        if table.nil? || index_name.nil?
          abort "Usage: belt destroy index <table> <IndexName>\n\n" \
                'Example: belt destroy index messages ConversationIndex'
        end

        new(table, index_name).remove
      end

      def self.parse_add_args(args)
        table = args.shift
        index_name = args.shift
        partition_key = nil
        sort_key = nil

        i = 0
        while i < args.length
          case args[i]
          when '--partition-key', '-p'
            i += 1
            partition_key = args[i]
          when '--sort-key', '-s'
            i += 1
            sort_key = args[i]
          end
          i += 1
        end

        if table.nil? || index_name.nil? || partition_key.nil?
          abort "Usage: belt generate index <table> <IndexName> --partition-key <key> [--sort-key <key>]\n\n" \
                'Example: belt generate index messages ConversationIndex --partition-key conversation_id'
        end

        [table, index_name, partition_key, sort_key]
      end

      def initialize(table, index_name, partition_key: nil, sort_key: nil)
        @table = table
        @index_name = index_name
        @partition_key = partition_key
        @sort_key = sort_key
      end

      def add
        validate_tf_exists!

        content = File.read(DYNAMODB_TF)
        table_resource = "aws_dynamodb_table\" \"#{@table}\""

        unless content.include?(table_resource)
          abort "Error: Table '#{@table}' not found in #{DYNAMODB_TF}.\n" \
                'Run `belt setup tables` first to generate the table.'
        end

        if content.include?("name            = \"#{@index_name}\"")
          puts "  skip    #{@index_name} (already exists on #{@table})"
          return
        end

        dynamo_pk = Belt::Inflector.camelize_lower(@partition_key)
        dynamo_sk = @sort_key ? Belt::Inflector.camelize_lower(@sort_key) : nil

        # Build the GSI block
        gsi_block = build_gsi_block(dynamo_pk, dynamo_sk)

        # Build attribute blocks for new keys
        attr_blocks = build_attribute_blocks(content, dynamo_pk, dynamo_sk)

        # Insert into the table resource
        insert_gsi(content, gsi_block, attr_blocks)

        puts "  create  #{@index_name} on #{@table} (partition: #{dynamo_pk}#{", sort: #{dynamo_sk}" if dynamo_sk})"
        puts "\n  Run `belt deploy` to apply. Adding a GSI to an existing table takes ~5-10 min."
      end

      def remove
        validate_tf_exists!

        content = File.read(DYNAMODB_TF)

        unless content.include?("name            = \"#{@index_name}\"")
          abort "Error: Index '#{@index_name}' not found in #{DYNAMODB_TF}."
        end

        # Remove the GSI block
        content.sub!(/\n\s*global_secondary_index \{\n\s*name\s*=\s*"#{Regexp.escape(@index_name)}".*?\n\s*\}/m, '')

        File.write(DYNAMODB_TF, content)
        puts "  remove  #{@index_name} from #{@table}"
        puts "\n  Run `belt deploy` to apply."
      end

      private

      def validate_tf_exists!
        return if File.exist?(DYNAMODB_TF)

        abort "Error: #{DYNAMODB_TF} not found.\nRun `belt setup tables` first."
      end

      def build_gsi_block(dynamo_pk, dynamo_sk)
        lines = []
        lines << '  global_secondary_index {'
        lines << "    name            = \"#{@index_name}\""
        lines << "    hash_key        = \"#{dynamo_pk}\""
        lines << "    range_key       = \"#{dynamo_sk}\"" if dynamo_sk
        lines << '    projection_type = "ALL"'
        lines << '  }'
        lines.join("\n")
      end

      def build_attribute_blocks(content, dynamo_pk, dynamo_sk)
        blocks = []
        [dynamo_pk, dynamo_sk].compact.each do |key|
          next if content.include?("name = \"#{key}\"")

          blocks << "\n  attribute {\n    name = \"#{key}\"\n    type = \"S\"\n  }"
        end
        blocks.join
      end

      def insert_gsi(content, gsi_block, attr_blocks)
        # Find the table's resource block and insert before point_in_time_recovery
        table_pattern = /resource "aws_dynamodb_table" "#{Regexp.escape(@table)}" \{.*?point_in_time_recovery/m

        content.sub!(table_pattern) do |match|
          # Insert attributes after last existing attribute block
          unless attr_blocks.empty?
            match.sub!(/(  attribute \{.*?\n  \})(?!.*attribute)/m) { |attr_match| "#{attr_match}#{attr_blocks}" }
          end

          # Insert GSI before point_in_time_recovery
          match.sub('point_in_time_recovery', "#{gsi_block}\n\n  point_in_time_recovery")
        end

        File.write(DYNAMODB_TF, content)
      end
    end
  end
end
