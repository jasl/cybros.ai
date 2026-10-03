# Hourly bounded cleanup of expired conversation-command replay evidence.
# The host reference has no foreign key, so a receipt never blocks host
# collection. Its own age-out or the parent Workspace's collector removes it.
class ConversationCommandReceipts::ReapJob < ApplicationJob
  BATCH = 1_000

  def perform
    reaped = ConversationCommandReceipt.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
