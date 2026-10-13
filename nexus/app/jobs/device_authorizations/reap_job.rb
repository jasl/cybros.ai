# Half-hourly bounded device-authorization cleanup. Both model phases remove
# acted-on rows from their source set, so a full batch schedules one cursorless
# continuation; a partial pass sleeps until the next recurring wake.
class DeviceAuthorizations::ReapJob < ApplicationJob
  BATCH = DeviceAuthorization::Convergence::BATCH_SIZE

  def perform
    result = DeviceAuthorization.reap(batch_size: BATCH)
    self.class.perform_later if result.more?
  end
end
