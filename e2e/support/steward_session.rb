require "monitor"
require_relative "browser_actor"
require_relative "session_sign_in_budget"

module E2E
  # ONE SIGNED-IN STEWARD BROWSER PER JOURNEY PROCESS. The multi-test rho
  # files each launched a Chrome and signed the steward in from `setup`, so
  # a file of eight tests paid eight launches and eight grants of the
  # 10-per-190 s sign-in ledger for plumbing none of its assertions are
  # about. The world's owner browser is already shared this way
  # (ActorProvisioning#with_owner_browser); this is the same shape for the
  # steward. Memoised per (server, Human) under a Monitor, closed when the
  # run ends. The first call is exactly the sign-in every setup used to do;
  # a test's setup then visits the dashboard and asserts it, so a test that
  # broke the session fails the NEXT test's setup loudly, never silently.
  module StewardSession
    @speakers = {}
    @monitor = Monitor.new

    class << self
      def actor(base_url:, human:)
        @monitor.synchronize do
          install_close_hook
          @speakers[[base_url, human.email]] ||= sign_in(BrowserActor.new(base_url), human)
        end
      end

      def close_all
        speakers = @monitor.synchronize { @speakers.values.tap { @speakers = {} } }
        speakers.each(&:close)
      end

      private

        # Runs outside any test, so it raises rather than asserts.
        def sign_in(actor, human)
          page = actor.page
          actor.visit("/session/new")
          page.fill_in "Email", with: human.email
          page.fill_in "Password", with: human.password
          SessionSignInBudget.consume
          page.click_button "Sign in"
          raise "the steward could not reach the dashboard after signing in" unless page.has_text?("Dashboard")

          actor
        rescue StandardError
          actor.close
          raise
        end

        def install_close_hook
          return if @close_hook_installed

          @close_hook_installed = true
          Minitest.after_run { StewardSession.close_all } if defined?(Minitest)
        end
    end
  end
end
