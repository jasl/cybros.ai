# Daily bounded collection of aged unreferenced fragments. A contested row is
# skipped, so continuation follows the scanned source window, not deletions.
class ContentFragments::ReapJob < ApplicationJob
  BATCH = ContentFragment::REAP_BATCH_SIZE

  def perform(after_created_at = nil, after_id = 0)
    result = ContentFragment.reap(
      batch: BATCH, after_created_at: after_created_at, after_id: after_id
    )
    self.class.perform_later(*result.cursor) if result.more?
  end
end
