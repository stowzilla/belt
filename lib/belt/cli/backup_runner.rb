# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

module Belt
  module CLI
    class BackupRunner
      def initialize(env, config, infra_dir:, app_name:)
        @env = env
        @config = config
        @infra_dir = infra_dir
        @app_name = app_name
        @timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
        @backup_bucket = sanitize_bucket_name("#{@app_name}-backups-#{@env}")
        @errors = []
        @summary = []
      end

      def run
        ensure_backup_bucket!
        backup_dynamodb if @config.dynamodb?
        backup_cognito if @config.cognito?
        backup_s3_buckets if @config.s3_buckets.any?
        cleanup_old_backups!
        print_summary

        abort "\n✗ Backup completed with errors (see above)" if @errors.any?
      end

      private

      # ─── Backup Bucket ───────────────────────────────────────────────

      def ensure_backup_bucket!
        # Check if bucket exists
        _, status = Open3.capture2('aws', 's3', 'ls', "s3://#{@backup_bucket}", err: File::NULL)
        return if status.success?

        puts "  📦 Creating backup bucket: #{@backup_bucket}"

        errors_before = @errors.size

        run_aws('s3', 'mb', "s3://#{@backup_bucket}", '--region', detect_region)

        # Enable versioning
        run_aws('s3api', 'put-bucket-versioning',
                '--bucket', @backup_bucket,
                '--versioning-configuration', 'Status=Enabled')

        # Block public access
        run_aws('s3api', 'put-public-access-block',
                '--bucket', @backup_bucket,
                '--public-access-block-configuration',
                'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true')

        if @errors.size > errors_before
          puts '  ⚠️  Backup bucket creation failed (see warnings below)'
        else
          puts '  ✅ Backup bucket created and secured'
        end
      end

      # ─── DynamoDB ────────────────────────────────────────────────────

      def backup_dynamodb
        puts '  💾 DynamoDB backups...'
        table_names = resolve_table_names

        if table_names.empty?
          @errors << 'Could not resolve DynamoDB table names'
          puts '  ⚠️  No table names found'
          return
        end

        # Filter tables if specific ones configured
        if @config.dynamodb_tables.is_a?(Array)
          table_names = table_names.select do |name|
            @config.dynamodb_tables.intersect?(name)
          end
        end

        # Ensure PITR is enabled on all tables
        table_names.each do |table_name|
          ensure_pitr(table_name)

          # Create on-demand snapshots
          create_snapshot(table_name)
        end

        @summary << "DynamoDB: #{table_names.size} table(s) — PITR verified + snapshot created"
      end

      def ensure_pitr(table_name)
        output, status = Open3.capture2(
          'aws', 'dynamodb', 'describe-continuous-backups',
          '--table-name', table_name
        )

        if status.success?
          data = JSON.parse(output)
          pitr_status = data.dig('ContinuousBackupsDescription', 'PointInTimeRecoveryDescription',
                                 'PointInTimeRecoveryStatus')

          return if pitr_status == 'ENABLED'
        end

        puts "    Enabling PITR for #{short_table_name(table_name)}..."
        run_aws('dynamodb', 'update-continuous-backups',
                '--table-name', table_name,
                '--point-in-time-recovery-specification', 'PointInTimeRecoveryEnabled=true')
      end

      def create_snapshot(table_name)
        short = short_table_name(table_name)
        backup_name = "#{short}-backup-#{@timestamp}"

        output, status = Open3.capture2e(
          'aws', 'dynamodb', 'create-backup',
          '--table-name', table_name,
          '--backup-name', backup_name
        )

        if status.success?
          puts "    ✅ Snapshot: #{short}"
        else
          puts "    ⚠️  Snapshot failed for #{short}: #{output.strip}"
        end
      end

      # ─── Cognito ─────────────────────────────────────────────────────

      def backup_cognito
        puts '  👥 Cognito backups...'
        pool_id = resolve_cognito_pool_id

        if pool_id.nil? || pool_id.empty?
          @errors << 'Could not resolve Cognito user pool ID'
          puts '  ⚠️  No Cognito pool ID found'
          return
        end

        exports_done = []

        if @config.cognito_exports.include?(:users)
          export_cognito_users(pool_id)
          exports_done << 'users'
        end

        if @config.cognito_exports.include?(:pool_config)
          export_cognito_pool_config(pool_id)
          exports_done << 'pool_config'
        end

        @summary << "Cognito: #{exports_done.join(', ')} exported" if exports_done.any?
      end

      def export_cognito_users(pool_id)
        all_users = []
        next_token = nil

        loop do
          args = ['aws', 'cognito-idp', 'list-users', '--user-pool-id', pool_id, '--max-items', '60']
          args += ['--starting-token', next_token] if next_token

          output, status = Open3.capture2(*args)
          break unless status.success?

          data = JSON.parse(output)
          all_users.concat(data['Users'] || [])

          next_token = data['NextToken']
          break if next_token.nil? || next_token.empty?

          puts '    Fetching next page of users...'
        end

        # Upload to backup bucket
        tmp_file = File.join(Dir.tmpdir, "cognito-users-#{@timestamp}.json")
        File.write(tmp_file, JSON.pretty_generate(all_users))

        run_aws('s3', 'cp', tmp_file, "s3://#{@backup_bucket}/cognito/users-#{@timestamp}.json", '--quiet')
        FileUtils.rm_f(tmp_file)

        puts "    ✅ Cognito users exported (#{all_users.size} users)"
      end

      def export_cognito_pool_config(pool_id)
        output, status = Open3.capture2(
          'aws', 'cognito-idp', 'describe-user-pool',
          '--user-pool-id', pool_id
        )

        unless status.success?
          @errors << 'Failed to export Cognito pool configuration'
          return
        end

        tmp_file = File.join(Dir.tmpdir, "cognito-pool-config-#{@timestamp}.json")
        File.write(tmp_file, output)

        run_aws('s3', 'cp', tmp_file, "s3://#{@backup_bucket}/cognito/pool-config-#{@timestamp}.json", '--quiet')
        FileUtils.rm_f(tmp_file)

        puts '    ✅ Cognito pool configuration exported'
      end

      # ─── S3 Bucket Sync ──────────────────────────────────────────────

      def backup_s3_buckets
        puts '  📄 S3 bucket backups...'

        @config.s3_buckets.each do |bucket_key|
          bucket_name = resolve_s3_bucket_name(bucket_key)

          if bucket_name.nil? || bucket_name.empty?
            puts "    ⚠️  Could not resolve bucket name for :#{bucket_key}"
            @errors << "Could not resolve S3 bucket: #{bucket_key}"
            next
          end

          puts "    Syncing #{bucket_name}..."
          output, status = Open3.capture2e(
            'aws', 's3', 'sync',
            "s3://#{bucket_name}",
            "s3://#{@backup_bucket}/s3/#{bucket_key}/#{@timestamp}/",
            '--quiet'
          )

          if status.success?
            puts "    ✅ #{bucket_key} synced"
          else
            puts "    ⚠️  #{bucket_key} sync failed: #{output.strip}"
            @errors << "S3 sync failed for #{bucket_key}"
          end
        end

        @summary << "S3: #{@config.s3_buckets.size} bucket(s) synced" if @errors.none? { |e| e.include?('S3') }
      end

      # ─── Cleanup ─────────────────────────────────────────────────────

      def cleanup_old_backups!
        puts '  🧹 Cleaning up old backups...'
        cleanup_cognito_backups if @config.cognito?
        cleanup_s3_backups if @config.s3_buckets.any?
        cleanup_dynamodb_snapshots if @config.dynamodb?
      end

      def cleanup_cognito_backups
        max_keep = @config.retention[:cognito] || 10

        %w[users pool-config].each do |prefix|
          output, status = Open3.capture2(
            'aws', 's3api', 'list-objects-v2',
            '--bucket', @backup_bucket,
            '--prefix', "cognito/#{prefix}-",
            '--query', 'Contents[].Key',
            '--output', 'json'
          )
          next unless status.success?

          keys = begin
            JSON.parse(output)
          rescue StandardError
            []
          end
          keys = Array(keys).compact.sort.reverse

          next if keys.size <= max_keep

          keys[max_keep..].each do |key|
            Open3.capture2('aws', 's3', 'rm', "s3://#{@backup_bucket}/#{key}")
          end
        end
      end

      def cleanup_s3_backups
        max_keep = @config.retention[:s3] || 10

        @config.s3_buckets.each do |bucket_key|
          output, status = Open3.capture2(
            'aws', 's3api', 'list-objects-v2',
            '--bucket', @backup_bucket,
            '--prefix', "s3/#{bucket_key}/",
            '--delimiter', '/',
            '--query', 'CommonPrefixes[].Prefix',
            '--output', 'json'
          )
          next unless status.success?

          prefixes = begin
            JSON.parse(output)
          rescue StandardError
            []
          end
          prefixes = Array(prefixes).compact.sort.reverse

          next if prefixes.size <= max_keep

          prefixes[max_keep..].each do |prefix|
            Open3.capture2e('aws', 's3', 'rm', "s3://#{@backup_bucket}/#{prefix}", '--recursive')
          end
        end
      end

      def cleanup_dynamodb_snapshots
        retention_days = @config.retention[:snapshots] || 90
        cutoff = Time.now - (retention_days * 86_400)
        cutoff_epoch = cutoff.to_i

        table_names = resolve_table_names
        table_names.each do |table_name|
          output, status = Open3.capture2(
            'aws', 'dynamodb', 'list-backups',
            '--table-name', table_name,
            '--time-range-upper-bound', cutoff_epoch.to_s
          )
          next unless status.success?

          data = begin
            JSON.parse(output)
          rescue StandardError
            {}
          end
          arns = (data['BackupSummaries'] || []).map { |b| b['BackupArn'] }.compact

          arns.each do |arn|
            Open3.capture2('aws', 'dynamodb', 'delete-backup', '--backup-arn', arn)
          end
        end
      end

      # ─── Table Discovery ──────────────────────────────────────────────

      def resolve_table_names
        @resolve_table_names ||= discover_tables_from_aws
      end

      def discover_tables_from_aws
        # List all DynamoDB tables matching the app-env prefix directly from AWS.
        # This is the source of truth — no Terraform output maintenance required.
        prefix = "#{@app_name}-#{@env}-"
        sanitized_prefix = sanitize_bucket_name(prefix)

        output, status = Open3.capture2('aws', 'dynamodb', 'list-tables', '--output', 'json')
        unless status.success?
          @errors << 'Failed to list DynamoDB tables from AWS'
          return []
        end

        all_tables = begin
          JSON.parse(output)['TableNames'] || []
        rescue StandardError
          []
        end

        all_tables.select { |t| t.start_with?(prefix) || t.start_with?(sanitized_prefix) }
      end

      # ─── Terraform Output Resolution ─────────────────────────────────

      def resolve_cognito_pool_id
        env_dir = File.join(@infra_dir, @env)
        return nil unless Dir.exist?(env_dir)

        Dir.chdir(env_dir) do
          output, status = Open3.capture2('terraform', 'output', '-json', 'user_pool_id', err: File::NULL)
          if status.success?
            val = begin
              JSON.parse(output)
            rescue StandardError
              nil
            end
            return val if val.is_a?(String) && !val.empty?
          end

          # Fallback: search all outputs
          output, status = Open3.capture2('terraform', 'output', '-json', err: File::NULL)
          if status.success?
            all_outputs = begin
              JSON.parse(output)
            rescue StandardError
              {}
            end
            %w[user_pool_id cognito_user_pool_id cognito_pool_id].each do |key|
              val = all_outputs.dig(key, 'value')
              return val if val.is_a?(String) && !val.empty?
            end
          end
        end

        nil
      end

      def resolve_s3_bucket_name(bucket_key)
        env_dir = File.join(@infra_dir, @env)
        return nil unless Dir.exist?(env_dir)

        name = Dir.chdir(env_dir) { fetch_s3_bucket_from_terraform(bucket_key) }
        name || discover_bucket_by_prefix(bucket_key)
      end

      def fetch_s3_bucket_from_terraform(bucket_key)
        key_name = "#{bucket_key}_bucket_name"
        output, status = Open3.capture2('terraform', 'output', '-json', key_name)
        if status.success?
          val = begin
            JSON.parse(output)
          rescue StandardError
            nil
          end
          return val if val.is_a?(String) && !val.empty?
        end

        fetch_s3_bucket_from_all_outputs(bucket_key)
      end

      def fetch_s3_bucket_from_all_outputs(bucket_key)
        output, status = Open3.capture2('terraform', 'output', '-json')
        return nil unless status.success?

        all_outputs = begin
          JSON.parse(output)
        rescue StandardError
          {}
        end

        [
          "#{bucket_key}_bucket_name",
          "#{bucket_key}_bucket",
          bucket_key.to_s
        ].each do |var|
          val = all_outputs.dig(var, 'value')
          return val if val.is_a?(String) && !val.empty?
        end

        nil
      end

      def discover_bucket_by_prefix(bucket_key)
        prefix = "#{@app_name}-#{bucket_key.to_s.tr('_', '-')}-#{@env}"
        output, status = Open3.capture2(
          'aws', 's3api', 'list-buckets',
          '--query', "Buckets[?starts_with(Name, '#{prefix}')].Name | [0]",
          '--output', 'text'
        )
        return nil unless status.success?

        val = output.strip
        val == 'None' ? nil : val
      end

      # ─── Helpers ─────────────────────────────────────────────────────

      def sanitize_bucket_name(name)
        # S3 bucket names must be DNS-compliant: lowercase, hyphens, no underscores
        name.tr('_', '-').downcase.gsub(/[^a-z0-9\-.]/, '-').gsub(/-{2,}/, '-')
      end

      def short_table_name(table_name)
        table_name.sub(/\A#{Regexp.escape(@app_name)}-#{Regexp.escape(@env)}-/, '')
      end

      def detect_region
        # Try AWS_DEFAULT_REGION, then AWS_REGION, then fall back to us-east-1
        ENV['AWS_DEFAULT_REGION'] || ENV['AWS_REGION'] || 'us-east-1'
      end

      def run_aws(*args)
        output, status = Open3.capture2e('aws', *args)
        return if status.success?

        @errors << "AWS CLI failed: aws #{args.join(' ')}"
        puts "    ⚠️  #{output.strip}" unless output.strip.empty?
      end

      def print_summary
        puts ''
        if @summary.any?
          puts "  ✅ Backup complete (#{@backup_bucket})"
          @summary.each { |s| puts "     • #{s}" }
        end
        return unless @errors.any?

        puts "  ⚠️  #{@errors.size} warning(s):"
        @errors.each { |e| puts "     • #{e}" }
      end
    end
  end
end
