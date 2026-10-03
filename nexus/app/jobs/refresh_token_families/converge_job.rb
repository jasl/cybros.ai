# Half-hourly bounded family convergence. Marker and reap walks carry
# independent cursors; nil parks a completed walk for the rest of this chain.
# The next recurring wake calls without arguments and restarts both walks.
class RefreshTokenFamilies::ConvergeJob < ApplicationJob
  BATCH = RefreshTokenFamily::Convergence::BATCH_SIZE

  def perform(marker_after_id = 0,
              reap_after = RefreshTokenFamily::Convergence::REAP_CURSOR_START)
    result = RefreshTokenFamily.converge(
      batch_size: BATCH,
      marker_after_id: marker_after_id,
      reap_after: reap_after
    )
    self.class.perform_later(*result.cursor) if result.more?
  end
end
