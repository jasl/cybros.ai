module ModelInvocations
  # The next provider-call ordinal. No partial unique index on active
  # attempts — it would freeze the status vocabulary into the schema — so
  # the parent Invocation lock the caller holds is the proof.
  module AttemptOrdinal
    # An Invocation may have at most one prepared-or-running Attempt. A second
    # would be a second live provider call for one piece of work, which is the
    # duplicate-charge shape the whole ordinal discipline exists to prevent.
    ACTIVE_EXISTS = :active_attempt_exists
    # Release policy per purpose, never a caller argument or an Account setting;
    # enforced in one place, `ApplyResult#requeue_transient`, where the current
    # ordinal is the calls spent.
    BUDGETS = {
      ModelInvocation::INFERENCE_REQUEST_PURPOSE => 3,
      ModelInvocation::CONVERSATION_REPLY_PURPOSE => 3,
      ModelInvocation::AGENT_RUN_TASK_PURPOSE => 3,
    }.freeze

    Result = Data.define(:ordinal, :refusal) do
      def self.allocated(ordinal) = new(ordinal: ordinal, refusal: nil)
      def self.refused(refusal) = new(ordinal: nil, refusal: refusal)

      def allocated? = refusal.nil?
    end

    # One past the highest ever allocated, never the highest live: a
    # terminal attempt's ordinal is part of its receipt's identity.
    def self.next_for(invocation)
      latest = invocation.attempts.order(ordinal: :desc).pick(:ordinal, :status)
      return Result.allocated(1) if latest.nil?

      ordinal, status = latest
      if ModelInvocationAttempt::ACTIVE_STATUSES.include?(status)
        return Result.refused(ACTIVE_EXISTS)
      end

      Result.allocated(ordinal + 1)
    end

    # Both consumers already own the current Attempt. Its ordinal is the
    # number of calls spent, so trust that closed fact instead of querying the
    # same Attempt table again on the send/apply hot path.
    def self.budget_spent?(invocation, ordinal:)
      budget = BUDGETS[invocation.purpose]
      return false if budget.nil?

      ordinal.to_i >= budget
    end
  end
end
