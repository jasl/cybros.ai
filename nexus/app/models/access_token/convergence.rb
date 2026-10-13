module AccessToken::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500
  PERMANENT_FENCE_SQL = <<~SQL.squish.freeze
    (
      access_tokens.task_executor_id IS NULL
      AND access_tokens.user_authority_generation <> users.authority_generation
    )
      OR (
        access_tokens.identity_recovery_generation IS NOT NULL
        AND access_tokens.identity_recovery_generation <> identities.credential_recovery_generation
      )
      OR refresh_token_families.revoked_at IS NOT NULL
      OR (
        access_tokens.task_executor_id IS NOT NULL
        AND (
          task_executors.status = 'revoked'
          OR access_tokens.credential_epoch <> task_executors.credential_epoch
        )
      )
  SQL

  ReapPhase = Data.define(:reaped, :scanned)

  class_methods do
    # Reaping gets half the budget up front, the marker walk every unused
    # slot. The marker budget counts scanned rows: the four-table fence has no
    # index, so an idle pass is bounded by its source window.
    def converge(now: Time.current, batch_size: BATCH_SIZE, marker_after_id: 0)
      reap_quota = (batch_size + 1) / 2
      first_reap = reap_batch(now:, batch_size: reap_quota)
      marker_allowance = batch_size - first_reap[:scanned]
      window = []
      marked = 0
      marker_cursor = marker_after_id
      if !marker_after_id.nil? && marker_allowance.positive?
        window, marked = mark_permanently_fenced(
          now:, batch_size: marker_allowance, after_id: marker_after_id
        )
        marker_cursor = window.length == marker_allowance ? window.last : nil
      end
      remaining = marker_allowance - window.length
      second_reap =
        if remaining.positive? && first_reap.more?
          reap_batch(now:, batch_size: remaining)
        end

      final_reap = second_reap || first_reap
      reaped = first_reap[:reaped] + (second_reap ? second_reap[:reaped] : 0)
      scanned = first_reap[:scanned] + (second_reap ? second_reap[:scanned] : 0) + window.length
      Rails.logger.info "event=access_tokens_converged marked=#{marked} reaped=#{reaped}"
      Sweeps::Pass.new(
        counts: { marked: marked, reaped: reaped, scanned: scanned },
        cursor: marker_cursor,
        more: batch_size.positive? &&
          (final_reap.more? || !marker_cursor.nil?)
      )
    end

    # The primary-key window comes first and the fence join applies only to
    # the windowed ids. Marking latency is bookkeeping: every usable? predicate
    # re-checks the fence live.
    def mark_permanently_fenced(now: Time.current, batch_size: BATCH_SIZE, after_id: 0)
      return [[], 0] unless batch_size.positive?

      window = where(id: (after_id + 1)..).order(:id).limit(batch_size).pluck(:id)
      marked = permanently_fenced.where(id: window).touch_all(:revoked_at, time: now)
      [window, marked]
    end

    def reap(now: Time.current, batch_size: BATCH_SIZE)
      reap_batch(now:, batch_size:)[:reaped]
    end

    private

      # The reap walks no cursor: every windowed row leaves the table.
      def reap_batch(now:, batch_size:)
        return Sweeps::Pass.new(counts: { reaped: 0, scanned: 0 }, more: false) unless
          batch_size.positive?

        cutoff = now - AccessToken::REAP_RETENTION
        revoked = reap_before(
          where(revoked_at: ..cutoff).order(:revoked_at, :id),
          batch_size
        )
        expired = reap_before(
          where(expires_at: ..cutoff).order(:expires_at, :id),
          batch_size - revoked.scanned
        )
        scanned = revoked.scanned + expired.scanned

        Sweeps::Pass.new(
          counts: { reaped: revoked.reaped + expired.reaped, scanned: scanned },
          more: scanned == batch_size
        )
      end

      # Each phase materializes one index-aligned source window before the
      # applying DELETE. A token matching both causes leaves the table in the
      # revoked phase, so it cannot consume the shared budget twice.
      def reap_before(scope, remaining)
        return ReapPhase.new(reaped: 0, scanned: 0) unless remaining.positive?

        window = scope.limit(remaining).pluck(:id)
        ReapPhase.new(
          reaped: delete_reap_window(window),
          scanned: window.length
        )
      end

      def delete_reap_window(window)
        where(id: window).delete_all
      end

      def permanently_fenced
        left_joins(:refresh_token_family, :task_executor, user: :identity)
          .where(revoked_at: nil)
          .where(PERMANENT_FENCE_SQL)
      end
  end
end
