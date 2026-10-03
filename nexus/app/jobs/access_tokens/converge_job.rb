# Bounded access-token convergence; the marker walk carries its cursor
# through the continuation, and the next recurring wake restarts from zero.
class AccessTokens::ConvergeJob < ApplicationJob
  BATCH = AccessToken::Convergence::BATCH_SIZE

  def perform(marker_after_id = 0)
    result = AccessToken.converge(
      batch_size: BATCH, marker_after_id: marker_after_id
    )
    self.class.perform_later(result.cursor) if result.more?
  end
end
