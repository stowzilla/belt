# frozen_string_literal: true

require_relative "belt/version"
require_relative "belt/parameters"

module Belt
  class AuthenticationError < StandardError; end
  class RecordNotFound < StandardError; end
  class ActionNotFound < StandardError; end
end

require_relative "belt_controller/base"
