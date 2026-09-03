# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require_relative 'nested_environment'

module Belt
  module CLI
    # Copies DynamoDB items from a parent environment into a nested child.
    #
    # Copy is skipped when the child table already has any items, so a PR
    # sync / second deploy will not clobber test data. If a copy fails the
    # child table is wiped (it was empty when we started) so the next deploy
    # retries.
    class DynamoCopier
      BATCH_SIZE = 25
      MAX_RETRIES = 8

      def initialize(nested_env, app_name:)
        @nested = nested_env
        @app_name = app_name
        @errors = []
      end

      def run
        pairs = table_pairs
        if pairs.empty?
          puts '  ℹ  No parent DynamoDB tables found to copy'
          return true
        end

        puts "  💾 Copying DynamoDB data from '#{@nested.parent}' (empty tables only)"

        copied = 0
        skipped = 0
        pairs.each do |parent_table, child_table|
          result = copy_pair(parent_table, child_table)
          case result
          when :copied then copied += 1
          when :skipped then skipped += 1
          end
        end

        puts "     copied #{copied}, skipped #{skipped}" \
             "#{@errors.any? ? ", #{@errors.size} error(s)" : ''}"
        @errors.empty?
      end

      private

      def copy_pair(parent_table, child_table)
        short = suffix_for(child_table, child_prefixes)

        unless table_exists?(child_table)
          puts "    ⚠  #{short}: child table missing — skip"
          return :skipped
        end

        if table_has_items?(child_table)
          puts "    skip  #{short} (already has data)"
          return :skipped
        end

        items = scan_items(parent_table)
        if items.nil?
          fail_table(short, "failed to scan parent #{parent_table}")
          return :failed
        end

        if items.empty?
          puts "    skip  #{short} (parent empty)"
          return :skipped
        end

        begin
          write_items(child_table, items)
          puts "    copy  #{short} (#{items.size} item#{'s' if items.size != 1})"
          :copied
        rescue StandardError => e
          wipe_table(child_table)
          fail_table(short, e.message)
          :failed
        end
      end

      def table_pairs
        parent_tables = tables_with_prefixes(parent_prefixes)
        child_tables = tables_with_prefixes(child_prefixes)
        pairs = {}

        parent_tables.each do |parent_table|
          suffix = suffix_for(parent_table, parent_prefixes)
          next if suffix.empty?

          child_prefixes.each do |prefix|
            candidate = "#{prefix}#{suffix}"
            next unless child_tables.include?(candidate)

            pairs[parent_table] = candidate
            break
          end
        end

        pairs
      end

      def parent_prefixes
        @parent_prefixes ||= prefixes_for(@nested.parent)
      end

      def child_prefixes
        @child_prefixes ||= prefixes_for(@nested.env)
      end

      def prefixes_for(env_name)
        raw = "#{@app_name}-#{env_name}-"
        sanitized = raw.tr('_', '-').downcase
        [raw, sanitized].uniq
      end

      def suffix_for(table_name, prefixes)
        prefixes.each do |prefix|
          return table_name.delete_prefix(prefix) if table_name.start_with?(prefix)
        end
        table_name
      end

      def tables_with_prefixes(prefixes)
        all_tables.select { |name| prefixes.any? { |prefix| name.start_with?(prefix) } }
      end

      def all_tables
        @all_tables ||= list_all_tables
      end

      def list_all_tables
        names = []
        start_name = nil
        loop do
          args = ['dynamodb', 'list-tables', '--output', 'json']
          args += ['--exclusive-start-table-name', start_name] if start_name
          data = aws_json(*args)
          return names if data.nil?

          names.concat(Array(data['TableNames']))
          start_name = data['LastEvaluatedTableName']
          break if start_name.nil? || start_name.empty?
        end
        names
      end

      def table_exists?(name)
        all_tables.include?(name)
      end

      def table_has_items?(table_name)
        data = aws_json('dynamodb', 'scan', '--table-name', table_name,
                        '--select', 'COUNT', '--limit', '1', '--output', 'json')
        return false if data.nil?

        data.fetch('Count', 0).to_i.positive?
      end

      def scan_items(table_name)
        items = []
        start_key = nil
        loop do
          args = ['dynamodb', 'scan', '--table-name', table_name, '--output', 'json']
          args += ['--exclusive-start-key', JSON.generate(start_key)] if start_key
          data = aws_json(*args)
          return nil if data.nil?

          items.concat(Array(data['Items']))
          start_key = data['LastEvaluatedKey']
          break if start_key.nil? || start_key.empty?
        end
        items
      end

      def write_items(table_name, items)
        items.each_slice(BATCH_SIZE) do |batch|
          request = {
            table_name => batch.map { |item| { 'PutRequest' => { 'Item' => item } } }
          }
          write_batch(request)
        end
      end

      def write_batch(request_items, attempt = 0)
        data = batch_write(request_items)
        raise "batch-write-item failed for #{request_items.keys.join(', ')}" if data.nil?

        unprocessed = data['UnprocessedItems']
        return if unprocessed.nil? || unprocessed.empty?
        raise "unprocessed items after #{MAX_RETRIES} retries" if attempt >= MAX_RETRIES

        sleep(0.2 * (2**attempt))
        write_batch(unprocessed, attempt + 1)
      end

      def batch_write(request_items)
        Tempfile.create(['belt-dynamo', '.json']) do |file|
          file.write(JSON.generate(request_items))
          file.flush
          aws_json('dynamodb', 'batch-write-item',
                   '--request-items', "file://#{file.path}",
                   '--output', 'json')
        end
      end

      def wipe_table(table_name)
        items = scan_items(table_name)
        return if items.nil? || items.empty?

        keys = key_attribute_names(table_name)
        return if keys.empty?

        items.each_slice(BATCH_SIZE) do |batch|
          request = {
            table_name => batch.map do |item|
              { 'DeleteRequest' => { 'Key' => item.slice(*keys) } }
            end
          }
          batch_write(request)
        end
      rescue StandardError
        nil
      end

      def key_attribute_names(table_name)
        data = aws_json('dynamodb', 'describe-table', '--table-name', table_name, '--output', 'json')
        return [] if data.nil?

        Array(data.dig('Table', 'KeySchema')).map { |key| key['AttributeName'] }.compact
      end

      def fail_table(short, message)
        @errors << "#{short}: #{message}"
        puts "    ⚠  #{short}: #{message} (will retry on next deploy if table is empty)"
      end

      def aws_json(*args)
        output, status = Open3.capture2('aws', *args)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
