# frozen_string_literal: true

module Belt
  module CLI
    class ExplainCommand
      DOCS_DIR = File.expand_path('../docs', __dir__)

      TOPICS = Dir.glob(File.join(DOCS_DIR, '*.md')).map do |path|
        File.basename(path, '.md')
      end.sort.freeze

      ALIASES = {
        'routes' => 'routing',
        'route' => 'routing',
        'router' => 'routing',
        'controller' => 'controllers',
        'model' => 'models',
        'activeitem' => 'models',
        'dynamodb' => 'models',
        'deploy' => 'deployment',
        'deploying' => 'deployment',
        'terraform' => 'deployment',
        'generate' => 'generators',
        'generator' => 'generators',
        'scaffold' => 'generators',
        'handler' => 'lambda_handler',
        'lambda' => 'lambda_handler',
        'entry_point' => 'lambda_handler',
        'entrypoint' => 'lambda_handler',
        'project' => 'structure',
        'layout' => 'structure',
        'directory' => 'structure',
        'logs' => 'observability',
        'logging' => 'observability',
        'metrics' => 'observability',
        'backup' => 'backups',
        'plugin' => 'plugins',
        'irb' => 'console',
        'repl' => 'console'
      }.freeze

      def self.run(args)
        if args.empty? || args.include?('--help') || args.include?('-h')
          puts usage
          return
        end

        topic = resolve_topic(args.first)

        if topic.nil?
          puts "Unknown topic: #{args.first}\n\n"
          puts 'Available topics:'
          TOPICS.each { |t| puts "  #{t}" }
          puts "\nRun `belt explain <topic>` for details."
          exit 1
        end

        display_topic(topic)
      end

      def self.resolve_topic(input)
        normalized = input.downcase.gsub('-', '_')
        return normalized if TOPICS.include?(normalized)
        return ALIASES[normalized] if ALIASES[normalized]

        # Fuzzy match: find topics that start with or contain the input
        match = TOPICS.find { |t| t.start_with?(normalized) }
        match || TOPICS.find { |t| t.include?(normalized) }
      end

      def self.display_topic(topic)
        path = File.join(DOCS_DIR, "#{topic}.md")
        content = File.read(path)
        puts content
      end

      def self.usage
        topic_list = TOPICS.map { |t| "  #{t}" }.join("\n")

        <<~USAGE
          Usage: belt explain <topic>

          Display documentation for a Belt concept or feature.

          Available topics:
          #{topic_list}

          Aliases:
            routes, route, router     → routing
            controller                → controllers
            model, activeitem         → models
            deploy, terraform         → deployment
            generate, scaffold        → generators
            handler, lambda           → lambda_handler
            project, layout           → structure
            logs, logging, metrics    → observability
            backup                    → backups
            plugin                    → plugins
            irb, repl                 → console

          Examples:
            belt explain routing
            belt explain controllers
            belt explain deploy
            belt explain models
        USAGE
      end
    end
  end
end
