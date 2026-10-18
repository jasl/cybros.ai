# Daily bounded physical collection of aged InferenceRequest tombstones. The recurring
# schedule is the level trigger; a full candidate window adds one continuation.
class InferenceRequests::ReapJob < ApplicationJob
  BATCH = 200

  def perform
    result = InferenceRequests::Reap.call(batch: BATCH)
    self.class.perform_later if result.more?
  end
end
