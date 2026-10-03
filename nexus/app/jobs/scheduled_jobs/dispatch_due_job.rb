class ScheduledJobs::DispatchDueJob < ApplicationJob
  def perform(cutoff = nil, after_at = nil, after_id = 0)
    result = ScheduledJobs::DispatchDue.call(cutoff: cutoff, after_at: after_at, after_id: after_id)
    self.class.perform_later(*result.cursor) if result.more?
  end
end
