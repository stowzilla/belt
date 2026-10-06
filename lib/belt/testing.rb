# frozen_string_literal: true

# Belt's test support. Opt-in: this is NOT loaded by `require 'belt'`, so it never ships
# in the production Lambda path. Require it from your test harness instead:
#
#   require 'belt'
#   require 'belt/testing'
#
# See Belt::Testing::E2E for the in-process, real-router end-to-end harness.

require_relative 'action_router'
require_relative 'testing/e2e'

module Belt
  # Namespace for Belt's test-support helpers (opt-in via `require 'belt/testing'`).
  module Testing
  end
end
