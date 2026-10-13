module RefreshTokenFamily::Convergence
  extend ActiveSupport::Concern

  BATCH_SIZE = 500
  # Address revocation or an epoch change permanently fences the lineage.
  # Temporary member unavailability alone does not; Agent removal advances
  # the epoch, so restoring the Profile cannot revive its old lineage.
  PERMANENT_FENCE_SQL = <<~SQL.squish.freeze
    task_executors.status = 'revoked'
      OR refresh_token_families.credential_epoch <> task_executors.credential_epoch
      OR (
        refresh_token_families.task_executor_id IS NULL
        AND (
          refresh_token_families.user_authority_generation <> users.authority_generation
          OR refresh_token_families.identity_recovery_generation <> identities.credential_recovery_generation
        )
      )
  SQL

  REAP_CURSOR_START = [nil, 0].freeze
  SweepBatch = Data.define(:changed, :scanned, :cursor)

  class_methods do
    # One budget across both walks, each with its own cursor because clean and
    # blocked rows both consume scan budget; a partial window parks at nil for
    # the chain.
    def converge(now: Time.current, batch_size: BATCH_SIZE, marker_after_id: 0,
                 reap_after: REAP_CURSOR_START)
      reap_quota = (batch_size + 1) / 2
      first_reap = reap_batch(now:, batch_size: reap_quota, after: reap_after)
      marker_allowance = batch_size - first_reap.scanned
      marker = mark_permanently_fenced_batch(
        now:, batch_size: marker_allowance, after_id: marker_after_id
      )
      remaining = marker_allowance - marker.scanned
      second_reap =
        if remaining.positive? && !first_reap.cursor.nil?
          reap_batch(now:, batch_size: remaining, after: first_reap.cursor)
        end

      reaped = first_reap.changed + (second_reap&.changed || 0)
      reap_scanned = first_reap.scanned + (second_reap&.scanned || 0)
      reap_cursor = second_reap ? second_reap.cursor : first_reap.cursor
      Rails.logger.info(
        "event=refresh_token_families_converged " \
          "marked=#{marker.changed} reaped=#{reaped} " \
          "scanned=#{marker.scanned + reap_scanned}"
      )
      # The cursor is the pair the job hand-carries: the marker walk's, then the reap walk's.
      Sweeps::Pass.new(
        counts: { marked: marker.changed, reaped: reaped, scanned: marker.scanned + reap_scanned },
        cursor: [marker.cursor, reap_cursor],
        more: batch_size.positive? &&
          (!marker.cursor.nil? || !reap_cursor.nil?)
      )
    end

    # The primary-key window comes first and the executor-join fence applies
    # only to the windowed ids. Marking latency is bookkeeping: every
    # authentication predicate re-checks status and epoch live.
    def mark_permanently_fenced(now: Time.current, batch_size: BATCH_SIZE, after_id: 0)
      return [[], 0] unless batch_size.positive?

      window = where(id: (after_id + 1)..).order(:id).limit(batch_size).pluck(:id)
      marked = permanently_fenced.where(id: window).touch_all(:revoked_at, time: now)
      [window, marked]
    end

    # Reapable once lapsed and its replay evidence is no longer needed; a row
    # this far past lapse can no longer rotate, so it is stable for a paged scan.
    def reap(now: Time.current, batch_size: BATCH_SIZE)
      reap_batch(now:, batch_size:, after: REAP_CURSOR_START).changed
    end

    private

      def mark_permanently_fenced_batch(now:, batch_size:, after_id:)
        if after_id.nil?
          return SweepBatch.new(changed: 0, scanned: 0, cursor: nil)
        end
        unless batch_size.positive?
          return SweepBatch.new(changed: 0, scanned: 0, cursor: after_id)
        end

        window, marked = mark_permanently_fenced(now:, batch_size:, after_id:)
        SweepBatch.new(
          changed: marked,
          scanned: window.length,
          cursor: window.length == batch_size ? window.last : nil
        )
      end

      # The window is materialized before any dependency check, so blocked
      # rows consume budget and the cursor walks past them for this chain.
      def reap_batch(now:, batch_size:, after:)
        if after.nil?
          return SweepBatch.new(changed: 0, scanned: 0, cursor: nil)
        end
        unless batch_size.positive?
          return SweepBatch.new(changed: 0, scanned: 0, cursor: after)
        end

        lapsed_before = now - RefreshTokenFamily::INACTIVITY_WINDOW -
          RefreshToken::POST_LAPSE_RETENTION
        source = where(last_used_at: ..lapsed_before)
        if after.first
          source = source.where(
            "(refresh_token_families.last_used_at, refresh_token_families.id) > (?, ?)",
            Time.zone.iso8601(after.first), after.last
          )
        end
        window = source.order(:last_used_at, :id).limit(batch_size)
          .pluck(:last_used_at, :id)
          .map { |last_used_at, id| [last_used_at.iso8601(6), id] }

        reaped = where(id: window.map(&:last), last_used_at: ..lapsed_before)
          .where.missing(:refresh_tokens, :access_tokens)
          .delete_all
        SweepBatch.new(
          changed: reaped,
          scanned: window.length,
          cursor: window.length == batch_size ? window.last : nil
        )
      end

      def permanently_fenced
        left_joins(:task_executor, user: :identity)
          .where(revoked_at: nil)
          .where(PERMANENT_FENCE_SQL)
      end
  end
end
