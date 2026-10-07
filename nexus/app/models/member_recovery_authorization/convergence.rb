module MemberRecoveryAuthorization::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500

  ReapPhase = Data.define(:reaped, :scanned)

  class_methods do
    # Three index-aligned phases sharing one budget: PostgreSQL cannot serve
    # an OR of three differently-indexed causes from one scan. Every windowed
    # row is deletable, so deletion advances each frontier and no cursor is needed.
    def reap(now: Time.current, batch_size: BATCH_SIZE)
      cutoff = now - MemberRecoveryAuthorization::EVIDENCE_RETENTION

      consumed = reap_phase(
        where.not(consumed_at: nil).where(consumed_at: ..cutoff)
          .order(:consumed_at, :id),
        batch_size
      )
      superseded = reap_phase(
        where.not(superseded_at: nil).where(superseded_at: ..cutoff)
          .order(:superseded_at, :id),
        batch_size - consumed.scanned
      )
      expired = reap_phase(
        where(consumed_at: nil, superseded_at: nil).where(expires_at: ..cutoff)
          .order(:expires_at, :id),
        batch_size - consumed.scanned - superseded.scanned
      )

      reaped = consumed.reaped + superseded.reaped + expired.reaped
      scanned = consumed.scanned + superseded.scanned + expired.scanned
      Rails.logger.info "event=member_recovery_authorizations_reaped reaped=#{reaped}"
      Sweeps::Pass.new(
        counts: { reaped: reaped, scanned: scanned },
        more: batch_size.positive? && scanned == batch_size
      )
    end

    private

      def reap_phase(scope, remaining)
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
  end
end
