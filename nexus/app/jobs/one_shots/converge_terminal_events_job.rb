module OneShots
  # The recurring floor plus best-effort wakes; level-triggered off the
  # frontier index, so a lost trigger costs only latency.
  class ConvergeTerminalEventsJob < ApplicationJob
    def perform(options = {})
      result = ConvergeTerminalEvents.call(invocation_id: options["invocation_id"])
      self.class.perform_later if result.more?
    end
  end
end
