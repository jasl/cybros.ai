# The graph's advance wake. Level-triggered: the scheduler re-reads
# readiness under the loop lock, so a duplicate kick is never a double start.
class Runs::ScheduleJob < ApplicationJob
  def perform(run_id)
    Runs::ScheduleReady.call(run_id: run_id)
  end
end
