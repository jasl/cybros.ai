# Hourly bounded cleanup of expired OneShot-create replay evidence. Receipt
# expiry affects storage only and never deletes the OneShot it referenced.
class OneShotCreateReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = OneShotCreateReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
