# frozen_string_literal: true

module BeltController
  # Rails-style halting for before_action callbacks.
  #
  # A before_action halts the request by producing a response. Either form works:
  #
  #   def require_admin!
  #     error_response('Forbidden', 403) unless admin?
  #   end
  #
  #   def require_admin!
  #     return if admin?
  #
  #     error_response('Forbidden', 403)
  #     Belt::Observability::Logger.warn('non-admin hit admin route')
  #   end
  #
  # Once a callback halts, the remaining callbacks, the action and the
  # after_actions are skipped, and that response is returned.
  #
  # Belt's response helpers are pure (they build and return a hash), so we
  # record any response built while a callback is running. That catches the
  # second form, where the response isn't the callback's return value.
  # Included by BeltController::Base after the response helpers so these
  # wrappers sit in front of them in the ancestor chain.
  module CallbackHalting
    # render builds its response via html_response, so it's covered too.
    %i[success_response error_response html_response head].each do |helper|
      define_method(helper) do |*args|
        response = super(*args)
        @__callback_response = response if @__running_callback
        response
      end
    end

    private

    # Run one before_action. Returns the response it produced (halt), or nil.
    # A returned response wins over one that was only built along the way.
    def run_halting_callback(method_name)
      @__callback_response = nil
      @__running_callback = true
      result = send(method_name)
      lambda_response?(result) ? result : @__callback_response
    ensure
      @__running_callback = false
    end
  end
end
