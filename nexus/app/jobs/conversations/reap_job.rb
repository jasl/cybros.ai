# Daily bounded pass over the tombstone frontier; one continuation when the
# window filled. Retained result owners remain in the set, so each hop
# advances past scanned rows; the recurring floor revisits them later.
class Conversations::ReapJob < ApplicationJob
  BATCH = 200

  def perform(after_tombstoned_at = nil, after_id = 0)
    result = Conversations::Reap.call(batch: BATCH,
      after_tombstoned_at: after_tombstoned_at, after_id: after_id)
    self.class.perform_later(*result.value.cursor) if result.value.more?
  end
end
