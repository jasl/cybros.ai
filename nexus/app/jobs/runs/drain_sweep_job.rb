# The drain sweep's shell: one bounded window over canceling loops, and the
# terminal-steps converger woken once when a drain was forced (Runs::DrainSweep).
class Runs::DrainSweepJob < ApplicationJob
  def perform(after_id = 0)
    result = Runs::DrainSweep.call(after_id: after_id)
    Runs::ConvergeTerminalStepsJob.perform_later if result[:escalated].positive?
    self.class.perform_later(result.cursor) if result.more?
  end
end
