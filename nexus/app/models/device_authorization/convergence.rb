module DeviceAuthorization::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500

  class_methods do
    # Expiry and terminal retention are separate index-aligned phases, each
    # materializing its window before applying by primary key; expiry gets half
    # the budget up front, terminal cleanup every unused slot.
    def reap(now: Time.current, batch_size: BATCH_SIZE)
      expiry_quota = (batch_size + 1) / 2
      first_expired, first_expiry_scanned = expire_phase(
        now: now, remaining: expiry_quota
      )
      deleted, terminal_scanned = delete_terminal_phase(
        now: now, remaining: batch_size - first_expiry_scanned
      )

      remaining = batch_size - first_expiry_scanned - terminal_scanned
      second_expired, second_expiry_scanned =
        if remaining.positive? && first_expiry_scanned == expiry_quota
          expire_phase(now: now, remaining: remaining)
        else
          [0, 0]
        end

      expired = first_expired + second_expired
      scanned = first_expiry_scanned + terminal_scanned + second_expiry_scanned
      more = batch_size.positive? && scanned == batch_size
      Rails.logger.info(
        "event=device_authorizations_reaped expired=#{expired} " \
          "deleted=#{deleted} scanned=#{scanned}"
      )
      Sweeps::Pass.new(counts: { expired: expired, deleted: deleted, scanned: scanned }, more: more)
    end

    private

      def expire_phase(now:, remaining:)
        return [0, 0] unless remaining.positive?

        candidates = live.where(expires_at: ..now)
          .order(:expires_at, :id).limit(remaining).pluck(:id)
        expired = live.where(id: candidates, expires_at: ..now)
          .update_all(status: "expired", updated_at: now)
        [expired, candidates.length]
      end

      def delete_terminal_phase(now:, remaining:)
        return [0, 0] unless remaining.positive?

        cutoff = now - DeviceAuthorization::TERMINAL_RETENTION
        terminal_statuses = statuses.keys - DeviceAuthorization::LIVE_STATUSES
        candidates = where(status: terminal_statuses, updated_at: ..cutoff)
          .order(:updated_at, :id).limit(remaining).pluck(:id)
        # Apply on the materialized primary keys alone: a cutoff range in the
        # DELETE lets the planner rediscover the cohort through the retention index.
        deleted = where(id: candidates).delete_all
        [deleted, candidates.length]
      end
  end
end
