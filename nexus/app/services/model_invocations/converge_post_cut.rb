module ModelInvocations
  # Converges every active Attempt whose parent is already terminal, copying the parent's class rather
  # than inventing one so two rows never disagree; a started attempt keeps settlement `pending`, since
  # the provider may still answer.
  class ConvergePostCut
    BUDGET = 500

    def self.call(...) = new(...).call

    def initialize(budget: BUDGET, after_id: 0)
      @budget = budget
      @after_id = after_id
    end

    def call
      candidates = frontier
      terminal_parent_ids = ModelInvocation
        .where(id: candidates.map(&:model_invocation_id), status: ModelInvocation::TERMINAL_STATUSES)
        .pluck(:id)
        .index_with(true)
      converged = candidates.count do |candidate|
        terminal_parent_ids.key?(candidate.model_invocation_id) && isolated(candidate)
      end

      Sweeps::Pass.new(
        counts: { converged: converged, scanned: candidates.length },
        cursor: candidates.last&.id || @after_id,
        more: candidates.length == @budget
      )
    end

    private

      # Ids off the frontier index, parents in one batch, so a healthy
      # in-flight row costs no lock attempt; each is rechecked under its parent lock.
      def frontier
        ModelInvocationAttempt
          .where(status: %w[prepared running])
          .where(id: (@after_id + 1)..)
          .order(:id)
          .limit(@budget)
          .pluck(:id, :model_invocation_id)
          .map do |id, model_invocation_id|
            Candidate.new(id: id, model_invocation_id: model_invocation_id)
          end
      end

      def converge(candidate)
        ApplicationRecord.transaction do
          invocation = ModelInvocation.lock.find_by(id: candidate.model_invocation_id)
          next false if invocation.nil?

          next false unless invocation.terminal?

          attempt = ModelInvocationAttempt.find_by(id: candidate.id)
          next false if attempt.nil?
          next false unless %w[prepared running].include?(attempt.status)

          next false if invariant_violation?(invocation, attempt)

          attempt.started? ? close_started(attempt, invocation) : release_unstarted(attempt, invocation)
        end
      end

      # One row's failure is one row's: an exception at id N must not leave
      # every higher id unconverged forever.
      def isolated(candidate)
        converge(candidate)
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "model_invocation_converge_failed", attempt_id: candidate.id })
        false
      end

      # A `completed` parent with an active Attempt is an invariant failure,
      # never a repair mapping: skipped, not raised, so the evidence survives
      # and the rest of the batch still converges.
      def invariant_violation?(invocation, attempt)
        return false unless invocation.completed?

        Rails.logger.error(
          "event=model_invocation_completed_with_active_attempt " \
          "model_invocation=#{invocation.public_id} attempt=#{attempt.public_id} " \
          "attempt_status=#{attempt.status}"
        )
        true
      end

      def release_unstarted(attempt, invocation)
        CancelUnstarted.call(attempt: attempt, terminal_status: invocation.status).terminalized?
      end

      # Settlement stays `pending`: the provider may still answer, and a local
      # cut does not make that evidence untrue.
      def close_started(attempt, invocation)
        attempt.update!(status: invocation.status, terminal_at: DatabaseClock.now)
        true
      end

    Candidate = Data.define(:id, :model_invocation_id)
  end
end
