# Hourly bounded cleanup of expired loop-append replay evidence. Receipt
# expiry affects storage only and never touches the graph it described.
class AgentLoopAppendReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = AgentLoopAppendReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
