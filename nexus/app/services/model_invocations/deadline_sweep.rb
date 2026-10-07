module ModelInvocations
  # The deadline sweep: a started attempt whose provider never answers ends here or nowhere. Level-triggered
  # off the indexed frontier, lock-free discovery, each candidate rechecked in its own transaction. A lost
  # enqueue is RedriveStalled's.
  class DeadlineSweep
    BUDGET = 500

    def self.call(...) = new(...).call

    def initialize(budget: BUDGET, after_id: 0)
      @budget = budget
      @after_id = after_id
    end

    def call
      # One clock read for the whole pass. A frontier that moved while the
      # pass ran belongs to the next pass, not to a row this one already
      # decided against.
      now = DatabaseClock.now
      candidates = frontier(now)

      timed_out = candidates.count { |candidate| isolated(candidate, now) }
      Sweeps::Pass.new(
        counts: { timed_out: timed_out, scanned: candidates.length },
        cursor: candidates.last&.id || @after_id,
        more: candidates.length == @budget
      )
    end

    private

      # Keyset by id, against the partial index that exists for exactly this
      # scan and had no reader until now. No join before the LIMIT: the
      # candidate set is ids, and everything else is read under the locks.
      def frontier(now)
        ModelInvocationAttempt
          .where(status: %w[prepared running])
          .where(deadline_at: ..now)
          .where(id: (@after_id + 1)..)
          .order(:id)
          .limit(@budget)
          .pluck(:id, :model_invocation_id)
          .map do |id, model_invocation_id|
            Candidate.new(id: id, model_invocation_id: model_invocation_id)
          end
      end

      # One row's failure is one row's: a keyset walk that aborts leaves every
      # higher id unreaped, holding budget nobody can get back.
      def isolated(candidate, now)
        settle(candidate, now)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "model_invocation_deadline_settle_failed", attempt_id: candidate.id })
        false
      end

      # Its own transaction and parent lock: whoever committed first wins,
      # and this returns false without writing.
      def settle(candidate, now)
        ApplicationRecord.transaction do
          invocation = ModelInvocation.lock.find_by(id: candidate.model_invocation_id)
          next false if invocation.nil?

          attempt = ModelInvocationAttempt.find_by(id: candidate.id)
          next false if attempt.nil?
          next false unless expired?(attempt, now)

          # A terminal parent is the post-cut converger's case: answering
          # `timed_out` over its cut would make two rows contradict.
          next false if invocation.terminal?

          if attempt.started?
            close_started(attempt, invocation, now)
          else
            release_unstarted(attempt, invocation, now)
          end
        end
      end

      def expired?(attempt, now)
        %w[prepared running].include?(attempt.status) &&
          attempt.deadline_at <= now
      end

      # Never called a provider. The command refuses a started attempt on
      # its own, so a start that won the race is the next pass's business.
      def release_unstarted(attempt, invocation, now)
        result = CancelUnstarted.call(
          attempt: attempt, terminal_status: "timed_out", at: now
        )
        return false unless result.terminalized?

        terminalize_parent(invocation, now)
        true
      end

      # Spent its call: settlement stays `pending` for the late-evidence
      # window, and this writes only that no timely terminal arrived.
      def close_started(attempt, invocation, now)
        attempt.update!(status: "timed_out", terminal_at: now)
        terminalize_parent(invocation, now)
        true
      end

      # The parent ends with its ordinal under the same lock, with the
      # host's own key: two spellings of one condition would make the
      # sweep-vs-start race visible in `error_code`.
      def terminalize_parent(invocation, now)
        invocation.terminalize(
          status: "timed_out", reason_key: ProviderStart::DEADLINE_PASSED, at: now
        )
        invocation.converge_owner_later
      end

    Candidate = Data.define(:id, :model_invocation_id)
  end
end
