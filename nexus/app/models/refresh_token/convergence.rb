module RefreshToken::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500

  MarkerBatch = Data.define(:marked, :scanned, :cursor)
  ReapPhase = Data.define(:reaped, :scanned)

  class_methods do
    # Half the budget is reserved for reclamation so a marker backlog cannot
    # starve it; markers receive every unused slot.
    def converge(
      now: Time.current, batch_size: BATCH_SIZE,
      lapsed_after: nil, marker_after_id: 0
    )
      reap_quota = (batch_size + 1) / 2
      first = reap(now:, batch_size: reap_quota, lapsed_after:)
      marker_allowance = batch_size - first[:scanned]
      marker = mark_revoked_families(
        now:, batch_size: marker_allowance, after_id: marker_after_id
      )
      remaining = marker_allowance - marker.scanned
      second =
        if remaining.positive? && first.more?
          reap(now:, batch_size: remaining, lapsed_after: first.cursor)
        end

      reaped = first[:reaped] + (second ? second[:reaped] : 0)
      Rails.logger.info "event=refresh_tokens_converged marked=#{marker.marked} reaped=#{reaped}"
      final_reap = second || first
      # The cursor is the pair the job hand-carries: the lapsed walk's, then the marker walk's.
      Sweeps::Pass.new(
        counts: {
          marked: marker.marked,
          reaped: reaped,
          scanned: first[:scanned] + (second ? second[:scanned] : 0) + marker.scanned,
        },
        cursor: [final_reap.cursor, marker.cursor],
        more: final_reap.more? || !marker.cursor.nil?
      )
    end

    # The unrevoked-token window rides the `id WHERE revoked_at IS NULL`
    # partial frontier, then joins family authority; clean rows consume scan
    # budget and a completed pass parks at nil.
    def mark_revoked_families(
      now: Time.current, batch_size: BATCH_SIZE, after_id: 0
    )
      if after_id.nil? || !batch_size.positive?
        return MarkerBatch.new(marked: 0, scanned: 0, cursor: after_id)
      end

      window = where(revoked_at: nil).where(id: (after_id + 1)..)
        .order(:id).limit(batch_size).pluck(:id)
      marked = joins(:refresh_token_family)
        .where(id: window, revoked_at: nil)
        .where.not(refresh_token_families: { revoked_at: nil })
        .touch_all(:revoked_at, time: now)

      MarkerBatch.new(
        marked: marked,
        scanned: window.length,
        cursor: window.length == batch_size ? window.last : nil
      )
    end

    # Three index-aligned phases: revoked and consumed evidence self-advance
    # by deletion; the lapsed arm walks families (which outlive their tokens
    # and so carry a cursor) and deletes each one's current token.
    def reap(now: Time.current, batch_size: BATCH_SIZE, lapsed_after: nil)
      evidence_cutoff = now - RefreshToken::EVIDENCE_RETENTION
      lapsed_before = now - RefreshTokenFamily::INACTIVITY_WINDOW -
        RefreshToken::POST_LAPSE_RETENTION

      revoked = reap_evidence(
        where(revoked_at: ..evidence_cutoff).order(:revoked_at, :id),
        batch_size
      )
      consumed = reap_evidence(
        where(consumed_at: ..evidence_cutoff).order(:consumed_at, :id),
        batch_size - revoked.scanned
      )
      lapsed, window, lapsed_cursor = reap_lapsed_families(
        lapsed_before: lapsed_before,
        after: lapsed_after,
        remaining: batch_size - revoked.scanned - consumed.scanned
      )
      scanned = revoked.scanned + consumed.scanned + window.length

      Sweeps::Pass.new(
        counts: { reaped: revoked.reaped + consumed.reaped + lapsed, scanned: scanned },
        cursor: lapsed_cursor,
        more: batch_size.positive? && scanned == batch_size
      )
    end

    private

      def reap_evidence(scope, remaining)
        return ReapPhase.new(reaped: 0, scanned: 0) unless remaining.positive?

        window = scope.limit(remaining).pluck(:id)
        ReapPhase.new(
          reaped: delete_evidence_window(window),
          scanned: window.length
        )
      end

      def delete_evidence_window(window)
        where(id: window).delete_all
      end

      def reap_lapsed_families(lapsed_before:, after:, remaining:)
        # false is the continuation-only parked sentinel. nil remains the
        # public no-cursor start so existing callers and recurring wakes begin
        # a fresh pass; a starved phase preserves whichever state it received.
        return [0, [], after] if after == false || !remaining.positive?

        scope = RefreshTokenFamily.where(last_used_at: ..lapsed_before)
        if after
          scope = scope.where(
            "(refresh_token_families.last_used_at, refresh_token_families.id) > (?, ?)",
            Time.zone.iso8601(after.first), after.last
          )
        end
        window = scope.order(:last_used_at, :id).limit(remaining)
          .pluck(:last_used_at, :id)
          .map { |last_used_at, id| [last_used_at.iso8601(6), id] }

        deleted = where(
          refresh_token_family_id: window.map(&:last),
          revoked_at: nil, consumed_at: nil, superseded_by_id: nil
        ).delete_all
        cursor = window.length == remaining ? window.last : false
        [deleted, window, cursor]
      end
  end
end
