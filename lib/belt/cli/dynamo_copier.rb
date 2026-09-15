# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'

module Belt
  module CLI
    # Copies DynamoDB items between two sets of tables identified by name
    # prefix (typically `<app>-<env>-`). Used both by the nested-environment
    # (PR preview) deploy hook and the standalone `belt db:copy` command.
    #
    # By default, copy is skipped when the destination table already has any
    # items, so re-running against a live environment will not clobber data.
    # Pass `force: true` to overwrite non-empty destination tables anyway.
    # If a copy fails, the destination table is wiped back to its starting
    # state (empty, or restored — best effort) so a retry starts clean.
    class DynamoCopier
      BATCH_SIZE = 25
      MAX_RETRIES = 8

      # Belt's `cognito_authenticatable` convention: the identity table is
      # `<app>-<env>-users`, its primary key attribute is `id` (the Cognito
      # `sub`), and it carries an `email` attribute. A Cognito `sub` is unique
      # *per user pool*, and each environment has its own pool — so the same
      # human has a different `id` in every environment. Any row that
      # references a user by sub therefore has a stale reference the moment it
      # crosses an environment boundary.
      #
      # `cognito_sub` is the conventional foreign-key attribute name for that
      # reference (see FeatureParity's Membership, Belt's invitation pattern).
      # When a referencing row also carries an `email`, we can re-anchor it to
      # the destination environment's user with the same email.
      IDENTITY_TABLE_SUFFIX = 'users'
      IDENTITY_ID_ATTR = 'id'
      IDENTITY_EMAIL_ATTR = 'email'
      IDENTITY_FK_ATTR = 'cognito_sub'

      # from_prefixes / to_prefixes: array of candidate table-name prefixes
      #   (the source/destination env's tables are matched against these).
      # from_profile / to_profile: AWS_PROFILE to use when reading the source
      #   / writing the destination, respectively (nil = use current
      #   credentials / AWS_PROFILE already in the environment).
      # label: short description used in log output (e.g. "dev01 → dev01-pr").
      # remap_identity: when true, re-anchor Cognito-sub foreign keys to the
      #   destination environment's users by email (see IDENTITY_* above). The
      #   users table itself is left untouched so the destination keeps its own
      #   pool's identities. Defaults to true — copying identity-referencing
      #   rows verbatim across environments silently hides the data (the row
      #   points at a sub that doesn't exist in the destination pool).
      def initialize(from_prefixes:, to_prefixes:, from_profile: nil, to_profile: nil,
                     force: false, label: nil, remap_identity: true)
        @from_prefixes = Array(from_prefixes)
        @to_prefixes = Array(to_prefixes)
        @from_profile = from_profile
        @to_profile = to_profile
        @force = force
        @label = label
        @remap_identity = remap_identity
        @errors = []
      end

      # rubocop:disable Naming/PredicateMethod
      def run
        # rubocop:enable Naming/PredicateMethod
        pairs = table_pairs
        if pairs.empty?
          puts '  ℹ  No matching DynamoDB tables found to copy'
          return true
        end

        mode = @force ? 'overwriting existing data' : 'empty tables only'
        puts "  💾 Copying DynamoDB data#{" (#{@label})" if @label} (#{mode})"

        copied = 0
        skipped = 0
        pairs.each do |source_table, dest_table|
          result = copy_pair(source_table, dest_table)
          case result
          when :copied then copied += 1
          when :skipped then skipped += 1
          end
        end

        puts "     copied #{copied}, skipped #{skipped}" \
             "#{", #{@errors.size} error(s)" if @errors.any?}"
        @errors.empty?
      end

      private

      def copy_pair(source_table, dest_table)
        short = suffix_for(dest_table, @to_prefixes)

        # The identity (users) table is left alone when remapping: the
        # destination environment's Cognito pool is authoritative for who its
        # users are and what `sub` each one has. Overwriting it with the
        # source pool's identities would create user rows that can never
        # authenticate here (their sub belongs to the other pool).
        if @remap_identity && identity_table?(short)
          puts "    skip  #{short} (identity table — destination pool is authoritative)"
          return :skipped
        end

        unless table_exists?(dest_table, profile: @to_profile)
          puts "    ⚠  #{short}: destination table missing — skip"
          return :skipped
        end

        if !@force && table_has_items?(dest_table, profile: @to_profile)
          puts "    skip  #{short} (already has data)"
          return :skipped
        end

        items = scan_items(source_table, profile: @from_profile)
        if items.nil?
          fail_table(short, "failed to scan source #{source_table}")
          return :failed
        end

        if items.empty?
          puts "    skip  #{short} (source empty)"
          return :skipped
        end

        items, remapped, dropped = remap_identity_refs(items) if @remap_identity

        begin
          wipe_table(dest_table, profile: @to_profile) if @force
          write_items(dest_table, items, profile: @to_profile)
          suffix = ''
          if @remap_identity && (remapped.to_i.positive? || dropped.to_i.positive?)
            parts = []
            parts << "#{remapped} re-anchored" if remapped.to_i.positive?
            parts << "#{dropped} unmatched" if dropped.to_i.positive?
            suffix = ", #{parts.join(', ')}"
          end
          puts "    copy  #{short} (#{items.size} item#{'s' if items.size != 1}#{suffix})"
          :copied
        rescue StandardError => e
          wipe_table(dest_table, profile: @to_profile)
          fail_table(short, e.message)
          :failed
        end
      end

      def identity_table?(suffix)
        suffix == IDENTITY_TABLE_SUFFIX
      end

      # Re-anchors Cognito-sub foreign keys to the destination environment's
      # users. For each item that carries both an email and a `cognito_sub`,
      # the sub is rewritten to the destination user with the same email. Items
      # whose email has no destination user keep their attributes but have the
      # stale sub cleared, so they surface as unclaimed (e.g. a pending
      # invitation) rather than pointing at a nonexistent identity.
      #
      # Returns [items, remapped_count, dropped_count].
      def remap_identity_refs(items)
        map = destination_email_to_id
        remapped = 0
        dropped = 0

        rewritten = items.map do |item|
          fk = item[IDENTITY_FK_ATTR]
          email_attr = item[IDENTITY_EMAIL_ATTR]
          # Only touch rows that actually reference an identity by sub AND
          # carry an email to re-anchor on. Everything else passes through.
          next item unless fk.is_a?(Hash) && fk.key?('S') && !fk['S'].to_s.empty?
          next item unless email_attr.is_a?(Hash) && !email_attr['S'].to_s.empty?

          email = email_attr['S'].to_s.downcase
          dest_id = map[email]

          if dest_id
            next item if dest_id == fk['S']

            remapped += 1
            item.merge(IDENTITY_FK_ATTR => { 'S' => dest_id })
          else
            dropped += 1
            item.reject { |key, _| key == IDENTITY_FK_ATTR }
          end
        end

        [rewritten, remapped, dropped]
      end

      # email (downcased) => destination user id (Cognito sub), built from the
      # destination environment's users table as it exists right now.
      def destination_email_to_id
        @destination_email_to_id ||= begin
          table = dest_identity_table
          map = {}
          if table
            items = scan_items(table, profile: @to_profile) || []
            items.each do |item|
              email = item.dig(IDENTITY_EMAIL_ATTR, 'S')
              id = item.dig(IDENTITY_ID_ATTR, 'S')
              map[email.to_s.downcase] = id if email && id
            end
          end
          map
        end
      end

      def dest_identity_table
        dest_tables = tables_with_prefixes(@to_prefixes, profile: @to_profile)
        dest_tables.find { |name| suffix_for(name, @to_prefixes) == IDENTITY_TABLE_SUFFIX }
      end

      def table_pairs
        source_tables = tables_with_prefixes(@from_prefixes, profile: @from_profile)
        dest_tables = tables_with_prefixes(@to_prefixes, profile: @to_profile)
        pairs = {}

        source_tables.each do |source_table|
          suffix = suffix_for(source_table, @from_prefixes)
          next if suffix.empty?

          @to_prefixes.each do |prefix|
            candidate = "#{prefix}#{suffix}"
            next unless dest_tables.include?(candidate)

            pairs[source_table] = candidate
            break
          end
        end

        pairs
      end

      def suffix_for(table_name, prefixes)
        prefixes.each do |prefix|
          return table_name.delete_prefix(prefix) if table_name.start_with?(prefix)
        end
        table_name
      end

      def tables_with_prefixes(prefixes, profile:)
        all_tables(profile: profile).select { |name| prefixes.any? { |prefix| name.start_with?(prefix) } }
      end

      def all_tables(profile:)
        @all_tables ||= {}
        @all_tables[profile] ||= list_all_tables(profile: profile)
      end

      def list_all_tables(profile:)
        names = []
        start_name = nil
        loop do
          args = ['dynamodb', 'list-tables', '--output', 'json']
          args += ['--exclusive-start-table-name', start_name] if start_name
          data = aws_json(*args, profile: profile)
          return names if data.nil?

          names.concat(Array(data['TableNames']))
          start_name = data['LastEvaluatedTableName']
          break if start_name.nil? || start_name.empty?
        end
        names
      end

      def table_exists?(name, profile:)
        all_tables(profile: profile).include?(name)
      end

      def table_has_items?(table_name, profile:)
        data = aws_json('dynamodb', 'scan', '--table-name', table_name,
                        '--select', 'COUNT', '--limit', '1', '--output', 'json', profile: profile)
        return false if data.nil?

        data.fetch('Count', 0).to_i.positive?
      end

      def scan_items(table_name, profile:)
        items = []
        start_key = nil
        loop do
          args = ['dynamodb', 'scan', '--table-name', table_name, '--output', 'json']
          args += ['--exclusive-start-key', JSON.generate(start_key)] if start_key
          data = aws_json(*args, profile: profile)
          return nil if data.nil?

          items.concat(Array(data['Items']))
          start_key = data['LastEvaluatedKey']
          break if start_key.nil? || start_key.empty?
        end
        items
      end

      def write_items(table_name, items, profile:)
        items.each_slice(BATCH_SIZE) do |batch|
          request = {
            table_name => batch.map { |item| { 'PutRequest' => { 'Item' => item } } }
          }
          write_batch(request, profile: profile)
        end
      end

      def write_batch(request_items, profile:, attempt: 0)
        data = batch_write(request_items, profile: profile)
        raise "batch-write-item failed for #{request_items.keys.join(', ')}" if data.nil?

        unprocessed = data['UnprocessedItems']
        return if unprocessed.nil? || unprocessed.empty?
        raise "unprocessed items after #{MAX_RETRIES} retries" if attempt >= MAX_RETRIES

        sleep(0.2 * (2**attempt))
        write_batch(unprocessed, profile: profile, attempt: attempt + 1)
      end

      def batch_write(request_items, profile:)
        Tempfile.create(['belt-dynamo', '.json']) do |file|
          file.write(JSON.generate(request_items))
          file.flush
          aws_json('dynamodb', 'batch-write-item',
                   '--request-items', "file://#{file.path}",
                   '--output', 'json', profile: profile)
        end
      end

      def wipe_table(table_name, profile:)
        items = scan_items(table_name, profile: profile)
        return if items.nil? || items.empty?

        keys = key_attribute_names(table_name, profile: profile)
        return if keys.empty?

        items.each_slice(BATCH_SIZE) do |batch|
          request = {
            table_name => batch.map do |item|
              { 'DeleteRequest' => { 'Key' => item.slice(*keys) } }
            end
          }
          batch_write(request, profile: profile)
        end
      rescue StandardError
        nil
      end

      def key_attribute_names(table_name, profile:)
        data = aws_json('dynamodb', 'describe-table', '--table-name', table_name, '--output', 'json', profile: profile)
        return [] if data.nil?

        Array(data.dig('Table', 'KeySchema')).map { |key| key['AttributeName'] }.compact
      end

      def fail_table(short, message)
        @errors << "#{short}: #{message}"
        puts "    ⚠  #{short}: #{message}"
      end

      def aws_json(*args, profile: nil)
        cmd = ['aws'] + args
        cmd += ['--profile', profile] if profile && !profile.empty?
        output, status = Open3.capture2(*cmd)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
