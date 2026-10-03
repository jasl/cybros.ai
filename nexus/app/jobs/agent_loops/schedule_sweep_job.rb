# The recurring floor under the schedule wakes (no heartbeats, only
# level-triggered state plus sweeps): a lost ScheduleJob delays advance by
# at most one period and never strands it.
class AgentLoops::ScheduleSweepJob < ApplicationJob
  def perform(schedule_after_id = 0, mail_after_id = 0)
    result = AgentLoops::ScheduleSweep.call(schedule_after_id:, mail_after_id:)
    self.class.perform_later(*result.cursor) if result.more?
  end
end
