# Daily bounded physical collection of aged OneShot tombstones. The recurring
# schedule is the level trigger; a full candidate window adds one continuation.
class OneShots::ReapJob < ApplicationJob
  BATCH = 200

  def perform
    result = OneShots::Reap.call(batch: BATCH)
    self.class.perform_later if result.more?
  end
end
