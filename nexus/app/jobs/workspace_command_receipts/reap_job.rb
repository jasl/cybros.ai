# The hourly receipt reap bounds storage only: expiry is already enforced
# on the accepting path against the persisted acceptance timestamp, so
# nothing depends on this job having run.
class WorkspaceCommandReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = WorkspaceCommandReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
