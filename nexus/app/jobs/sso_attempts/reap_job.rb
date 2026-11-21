class SsoAttempts::ReapJob < ApplicationJob
  BATCH = 500

  def perform
    self.class.perform_later if SsoAttempt.reap_expired(batch_size: BATCH) == BATCH
  end
end
