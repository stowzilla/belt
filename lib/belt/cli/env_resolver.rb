# frozen_string_literal: true

module Belt
  module CLI
    module EnvResolver
      def self.resolve(args)
        if args.first && !args.first.start_with?('-')
          args.shift
        else
          ENV['BELT_ENV']
        end
      end
    end
  end
end
