# Nightly bounded physical reclamation of aged loop tombstones. Level
# triggered: a full batch advances past retained cleanup owners. The next
# recurring pass starts over to reconsider those owners after relay converges.
class AgentLoops::ReapJob < ApplicationJob
  BATCH = 100

  def perform(after_tombstoned_at = nil, after_id = 0)
    result = AgentLoops::Reap.call(batch: BATCH,
      after_tombstoned_at: after_tombstoned_at, after_id: after_id)
    self.class.perform_later(*result.cursor) if result.more?
  end
end
