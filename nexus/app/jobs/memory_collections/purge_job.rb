class MemoryCollections::PurgeJob < ApplicationJob
  BATCH = 200

  def perform(after_deleted_at = nil, after_id = 0)
    result = MemoryCollections::Purge.call(batch: BATCH,
      after_deleted_at: after_deleted_at, after_id: after_id)
    self.class.perform_later(*result.cursor) if result.more?
  end
end
