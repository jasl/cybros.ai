module UsageBudgets
  # Revocation removes this window from admission and settlement; it does
  # not disable the payer or change entries already written. Without a usable
  # budget, admission has no spend cap. The stored key and reason are the replay gate;
  # no digest, since string equality already answers.
  class Revoke
    Result = Data.define(:outcome, :budget) do
      def revoked? = outcome == :revoked
      def not_authorized? = outcome == :not_authorized
      def invalid? = outcome == :invalid
      def already_revoked? = outcome == :already_revoked
      def conflict? = outcome == :conflict
    end

    class << self
      def call(actor:, budget:, operation_key:, reason: nil)
        unless UsageBudgets.valid_operation_key?(operation_key) && UsageBudgets.valid_reason?(reason)
          return refuse(:invalid)
        end
        return refuse(:not_authorized) unless authorized?(actor: actor, budget: budget)

        User.transaction do
          lock_principals(actor: actor, budget: budget)
          next refuse(:not_authorized) unless authorized?(actor: actor, budget: budget)

          # The budget after its principals (users before budgets): the verb
          # answers a replay by the key it reads under the lock, and a CAS on
          # `revoked_at` could not tell "already revoked, same key" from a rival.
          budget.lock!
          next settled_outcome(budget, operation_key, reason) if budget.revoked?

          budget.update!(
            revoked_at: DatabaseClock.now, revoked_by_public_id: actor.public_id,
            revoke_reason: reason, revoke_operation_key: operation_key
          )
          Result.new(outcome: :revoked, budget: budget)
        end
      end

      private

        def refuse(outcome) = Result.new(outcome: outcome, budget: nil)

        def authorized?(actor:, budget:)
          owner = budget.user
          return false if !actor.human? || !actor.active?

          owner.agent_member? ? owner.steward_id == actor.id : actor.admin?
        end

        def lock_principals(actor:, budget:)
          PrincipalLocks.descend(budget.user, actor)
        end

        # The single-transition row already carries its outcome; replay reads
        # it instead of writing again.
        def settled_outcome(budget, operation_key, reason)
          if budget.revoke_operation_key != operation_key
            refuse(:already_revoked)
          elsif budget.revoke_reason == reason
            Result.new(outcome: :revoked, budget: budget)
          else
            refuse(:conflict)
          end
        end
    end
  end
end
