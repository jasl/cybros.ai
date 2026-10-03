# A follower that outran the replay window re-reads the host's durable state.
# Events can expire while their conversation or loop is still running.
class ConversationEventItems::ReapJob < ApplicationJob
  BATCH = 5_000

  def perform
    reaped = ConversationEventItem.reap(batch: BATCH)
    self.class.perform_later if reaped == BATCH
  end
end
