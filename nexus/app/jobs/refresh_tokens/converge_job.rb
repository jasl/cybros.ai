# Half-hourly bounded refresh-token convergence. The lapsed-family and
# unrevoked-token marker walks carry independent cursors. A completed walk
# parks for the rest of the chain; the next recurring wake restarts both.
class RefreshTokens::ConvergeJob < ApplicationJob
  BATCH = RefreshToken::Convergence::BATCH_SIZE

  def perform(lapsed_after = nil, marker_after_id = 0)
    result = RefreshToken.converge(
      batch_size: BATCH,
      lapsed_after: lapsed_after,
      marker_after_id: marker_after_id
    )
    if result.more?
      lapsed_cursor, marker_cursor = result.cursor
      continuation = [lapsed_cursor]
      continuation << marker_cursor unless marker_cursor == 0
      self.class.perform_later(*continuation)
    end
  end
end
