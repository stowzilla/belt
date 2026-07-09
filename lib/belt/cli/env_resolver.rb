# frozen_string_literal: true

module Belt
  module CLI
    module EnvResolver
      # Resolve the target environment from CLI args or BELT_ENV.
      #
      # Accepts an optional "environment" keyword so terraform commands mirror
      # `belt generate environment <name>`:
      #   belt destroy environment dev
      #   belt apply environment staging
      # as well as the short form:
      #   belt destroy dev
      def self.resolve(args)
        args.shift if args.first == 'environment'

        if args.first && !args.first.start_with?('-')
          args.shift
        else
          ENV.fetch('BELT_ENV', nil)
        end
      end
    end
  end
end
