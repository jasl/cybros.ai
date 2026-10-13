# The expiry frontier advances by deletion, the fenced walk by its cursor;
# a full window schedules exactly one continuation.
class Sessions::ReapJob < ApplicationJob
  BATCH = Session::REAP_BATCH_SIZE

  def perform(fenced_after_id = 0)
    result = Session.reap(batch_size: BATCH, fenced_after_id: fenced_after_id)
    self.class.perform_later(result.cursor) if result.more?
  end
end
