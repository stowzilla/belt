# frozen_string_literal: true

module Belt
  VERSION = '0.6.1'

  # Ruby version new apps run on in Lambda. Rendered into the conveyor-belt
  # provider block (`ruby_version`) by `belt new` / `belt generate environment`.
  LAMBDA_RUBY_VERSION = '4.0'
end
