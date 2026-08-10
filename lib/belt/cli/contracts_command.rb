# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../route_dsl'
require_relative 'routes_command/schema_loader'

module Belt
  module CLI
    class ContractsCommand
      include RoutesCommand::SchemaLoader

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @options = {}
        parse_options(args)
      end

      def run
        contracts_file = find_contracts_file
        unless contracts_file
          abort 'Error: No contracts file found. ' \
                'Expected config/contracts.rb (or config/contracts.tf.rb, config/schema.tf.rb)'
        end

        models = load_contracts(contracts_file)

        if @options[:format] == 'json'
          output_json(models)
        else
          output_concise(models)
        end
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt contracts [options]'

          opts.on('-f', '--format FORMAT', 'Output format: concise (default), json') do |format|
            @options[:format] = format
          end

          opts.on('-g', '--grep PATTERN', 'Filter contracts matching pattern') do |pattern|
            @options[:grep] = pattern
          end

          opts.on('--file FILE', 'Path to contracts file (overrides auto-detection)') do |file|
            @options[:contracts_file] = file
          end

          opts.on('-h', '--help', 'Show this help') do
            puts opts
            exit
          end
        end.parse!(args)
      end

      def find_contracts_file
        if @options[:contracts_file]
          file = @options[:contracts_file]
          return file if File.exist?(file)

          abort "Error: Specified contracts file not found: #{file}"
        end

        candidates = [
          'config/contracts.rb',
          'config/contracts.tf.rb',
          'config/schema.tf.rb',
          'infrastructure/schema.tf.rb'
        ]
        candidates.find { |f| File.exist?(f) }
      end

      def load_contracts(file)
        Belt.instance_variable_set(:@application, nil)
        begin
          eval(File.read(file), binding, file) # rubocop:disable Security/Eval
        rescue StandardError => e
          abort "Error: Failed to load contracts file #{file}: #{e.message}"
        end

        schema = Belt.application.schema.to_h
        models = build_models_from_schema(schema)
        models = apply_grep(models) if @options[:grep]
        models
      end

      def apply_grep(models)
        pattern = Regexp.new(@options[:grep], Regexp::IGNORECASE)
        models.select do |m|
          m[:name].match?(pattern) ||
            m[:kind].match?(pattern) ||
            m[:description].match?(pattern)
        end
      end

      def output_json(models)
        puts JSON.pretty_generate(models: models)
      end

      def output_concise(models)
        return puts('No contracts defined.') if models.empty?

        requests = models.select { |m| m[:kind] == 'request' }
        responses = models.select { |m| m[:kind] == 'response' }

        if requests.any?
          puts 'REQUEST MODELS'
          puts '-' * 60
          requests.each { |m| print_model(m) }
          puts
        end

        if responses.any?
          puts 'RESPONSE MODELS'
          puts '-' * 60
          responses.each { |m| print_model(m) }
        end

        puts "\n#{models.length} contract(s) total (#{requests.length} request, #{responses.length} response)"
      end

      def print_model(model)
        required = model[:required] || []
        props = (model[:properties] || {}).map do |name, meta|
          type = meta['type'] || meta[:type] || 'string'
          req_marker = required.include?(name.to_s) ? ' *' : ''
          "#{name}:#{type}#{req_marker}"
        end

        puts "  #{model[:name]} (#{model[:kind]})"
        puts "    #{props.join(', ')}" if props.any?
      end
    end
  end
end
