# The recurring floor for park expiry and executor removal: one source
# window per pass, with a full page continuing from its last id.
class AgentRuns::Parks::TimeoutSweepJob < ApplicationJob
  def perform(after_id = 0)
    result = AgentRuns::Parks::TimeoutSweep.call(after_id: after_id)
    self.class.perform_later(result.cursor) if result.more?
  end
end
