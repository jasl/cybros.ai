# Level trigger + one continuation; woken from every invocation-terminal
# path and floored by the recurring schedule (the bulk cancellation kernel
# wakes nothing, by design — the floor converges it).
class AgentRuns::ConvergeTerminalStepsJob < ApplicationJob
  BATCH = 200

  def perform(after_id = 0, options = {})
    result = AgentRuns::ConvergeTerminalSteps.call(
      batch: BATCH, after_id: after_id, invocation_id: options["invocation_id"]
    )
    self.class.perform_later(result.cursor) if result.more?
  end
end
