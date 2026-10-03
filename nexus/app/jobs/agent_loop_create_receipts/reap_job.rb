# Hourly bounded cleanup of expired loop-create replay evidence. Receipt
# expiry affects storage only and never deletes the loop it referenced.
class AgentLoopCreateReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = AgentLoopCreateReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
