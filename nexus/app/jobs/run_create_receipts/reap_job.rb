# Hourly bounded cleanup of expired loop-create replay evidence. Receipt
# expiry affects storage only and never deletes the loop it referenced.
class RunCreateReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = RunCreateReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
