# frozen_string_literal: true

require 'open3'
require 'optparse'

module Belt
  module CLI
    class TasksCommand
      def self.run(args)
        new(args).run
      end

      # Check if a given command name looks like a rake task that exists
      def self.rake_task?(name)
        return false unless name.include?(':') || name.match?(/\A[a-z_]+\z/)
        return false unless File.exist?('Rakefile') || File.exist?('rakefile') || File.exist?('Rakefile.rb')

        # Only treat colon-namespaced commands as potential rake tasks to avoid
        # ambiguity with belt's own commands
        name.include?(':')
      end

      # Invoke a specific rake task by name
      def self.invoke(task_name, args)
        unless File.exist?('Rakefile') || File.exist?('rakefile') || File.exist?('Rakefile.rb')
          abort "Error: No Rakefile found. Cannot run task '#{task_name}'."
        end

        cmd = ['bundle', 'exec', 'rake', task_name] + args
        exec(*cmd)
      end

      def initialize(args)
        @options = {}
        parse_options(args)
      end

      def run
        abort 'Error: No Rakefile found. Add a Rakefile to your project to discover tasks.' unless rakefile_available?

        tasks = load_tasks
        tasks = apply_grep(tasks) if @options[:grep]

        if tasks.empty?
          puts 'No rake tasks found.'
        else
          output_tasks(tasks)
        end
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt tasks [options]'

          opts.on('-g', '--grep PATTERN', 'Filter tasks matching pattern') do |pattern|
            @options[:grep] = pattern
          end

          opts.on('-a', '--all', 'Show all tasks (including those without descriptions)') do
            @options[:all] = true
          end

          opts.on('-h', '--help', 'Show this help') do
            puts opts
            exit
          end
        end.parse!(args)
      end

      def rakefile_available?
        File.exist?('Rakefile') || File.exist?('rakefile') || File.exist?('Rakefile.rb')
      end

      def load_tasks
        cmd = @options[:all] ? %w[bundle exec rake -T -A] : %w[bundle exec rake -T]
        output, status = Open3.capture2(*cmd, err: File::NULL)

        abort 'Error: Failed to load rake tasks. Ensure `bundle install` has been run.' unless status.success?

        parse_task_output(output)
      end

      def parse_task_output(output)
        output.lines.filter_map do |line|
          match = line.match(/^rake\s+(\S+)\s*#\s*(.*)$/)
          next unless match

          { name: match[1], description: match[2].strip }
        end
      end

      def apply_grep(tasks)
        pattern = Regexp.new(@options[:grep], Regexp::IGNORECASE)
        tasks.select do |t|
          t[:name].match?(pattern) || t[:description].match?(pattern)
        end
      end

      def output_tasks(tasks)
        name_w = [tasks.map { |t| t[:name].length }.max, 4].max

        tasks.each do |t|
          puts "belt #{t[:name].ljust(name_w)}  # #{t[:description]}"
        end
      end
    end
  end
end
