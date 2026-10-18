# Hourly bounded cleanup of expired InferenceRequest-create replay evidence. Receipt
# expiry affects storage only and never deletes the InferenceRequest it referenced.
class InferenceRequestCreateReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = InferenceRequestCreateReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
