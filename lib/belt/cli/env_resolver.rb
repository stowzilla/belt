# frozen_string_literal: true

module Belt
  module CLI
    module EnvResolver
      def self.resolve(args)
        if args.first && !args.first.start_with?('-')
          args.shift
        else
          ENV.fetch('BELT_ENV', nil)
        end
      end
    end
  end
end
