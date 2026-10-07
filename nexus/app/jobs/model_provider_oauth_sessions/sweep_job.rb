module ModelProviderOAuthSessions
  # Wakes the three clock-driven sweeps, holding no authority. Stale
  # dispatches seal first: a session expired before its stale child was
  # sealed would leave that child dispatching against a parent nobody advances.
  class SweepJob < ApplicationJob
    queue_as :default

    # Terminal sessions retain their diagnostic history for 30 days.
    RETENTION_DAYS = 30

    def perform(limit: 100, now: Time.current, after_updated_at: nil, after_id: 0)
      sweeps = ModelProviders::CodexAuthorization::Sweeps
      # Only the recurring first hop wakes the clock sweeps. Collection's
      # continuation skips retained parents under the same retention cutoff.
      unless after_updated_at
        sweeps.seal_stale_dispatches(now: now, limit: limit)
        sweeps.expire_closed_windows(now: now, limit: limit)
      end
      result = sweeps.collect_terminal_sessions(before: now - RETENTION_DAYS.days, limit: limit,
        after_updated_at: after_updated_at, after_id: after_id)
      if result.more?
        self.class.perform_later(limit: limit, now: now,
          after_updated_at: result.cursor.first, after_id: result.cursor.last)
      end
    end
  end
end
