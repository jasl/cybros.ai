# Every windowed row is deleted, so each phase's frontier advances by
# deletion alone; a full budget schedules exactly one continuation.
class MemberRecoveryAuthorizations::ReapJob < ApplicationJob
  BATCH = MemberRecoveryAuthorization::Convergence::BATCH_SIZE

  def perform
    result = MemberRecoveryAuthorization.reap(batch_size: BATCH)
    self.class.perform_later if result.more?
  end
end
