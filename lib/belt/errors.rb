# frozen_string_literal: true

module Belt
  class AuthenticationError < StandardError; end
  class RecordNotFound < StandardError; end
  class ActionNotFound < StandardError; end
  class TemplateNotFound < StandardError; end
end
