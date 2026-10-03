# The drain sweep's shell: one bounded window over canceling loops, and the
# terminal-steps converger woken once when a drain was forced (AgentLoops::DrainSweep).
class AgentLoops::DrainSweepJob < ApplicationJob
  def perform(after_id = 0)
    result = AgentLoops::DrainSweep.call(after_id: after_id)
    AgentLoops::ConvergeTerminalStepsJob.perform_later if result[:escalated].positive?
    self.class.perform_later(result.cursor) if result.more?
  end
end
