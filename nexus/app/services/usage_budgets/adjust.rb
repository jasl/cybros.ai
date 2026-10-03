module UsageBudgets
  # Appends one attributed adjustment and moves the materialized head in the
  # same transaction. Revocation and expiry do not block it: Deficit repair
  # is a credit on a budget whose window may be gone.
  class Adjust
    Result = Data.define(:outcome, :entry) do
      def adjusted? = outcome == :adjusted
      def not_authorized? = outcome == :not_authorized
      def invalid? = outcome == :invalid
      def insufficient_headroom? = outcome == :insufficient_headroom
      def conflict? = outcome == :conflict
    end

    KINDS = { credit: "credit_adjustment", debit: "debit_adjustment" }.freeze

    class << self
      def call(actor:, budget:, kind:, amount:, operation_key:, reason: nil)
        amount = UsageBudgets.exact_nonnegative(amount)
        entry_kind = KINDS[kind]
        if amount.nil? || entry_kind.nil? ||
            !UsageBudgets.valid_operation_key?(operation_key) || !UsageBudgets.valid_reason?(reason)
          return refuse(:invalid)
        end
        return refuse(:not_authorized) unless authorized?(actor: actor, budget: budget)

        User.transaction do
          lock_principals(actor: actor, budget: budget)
          next refuse(:not_authorized) unless authorized?(actor: actor, budget: budget)

          # The budget after its principals (users before budgets): the replay
          # read, the headroom check and the head move must see one ledger,
          # and the unique operation key alone gives no stable loser.
          budget.lock!
          replay = find_replay(budget: budget, operation_key: operation_key)
          if replay
            next replay_outcome(replay, budget: budget, entry_kind: entry_kind,
              amount: amount, reason: reason)
          end

          if entry_kind == "debit_adjustment" && headroom_after_debit(budget, amount).negative?
            next refuse(:insufficient_headroom)
          end

          append(actor: actor, budget: budget, entry_kind: entry_kind, amount: amount,
            operation_key: operation_key, reason: reason)
        end
      end

      private

        def refuse(outcome) = Result.new(outcome: outcome, entry: nil)

        def authorized?(actor:, budget:)
          owner = budget.user
          return false if !actor.human? || !actor.active?

          if owner.agent_member?
            owner.steward_id == actor.id
          else
            actor.admin?
          end
        end

        def lock_principals(actor:, budget:)
          PrincipalLocks.descend(budget.user, actor)
        end

        # The key is scoped to the target, not a window: the same key on a
        # different budget is a conflict, not a second effect.
        def find_replay(budget:, operation_key:)
          UsageBudgetEntry.where(usage_budget_id: budget.user.usage_budgets.select(:id))
            .find_by(operation_key: operation_key)
        end

        def replay_outcome(entry, budget:, entry_kind:, amount:, reason:)
          return refuse(:conflict) if entry.usage_budget_id != budget.id

          exact = entry.kind == entry_kind && entry.amount == amount && entry.reason == reason
          exact ? Result.new(outcome: :adjusted, entry: entry) : refuse(:conflict)
        end

        def headroom_after_debit(budget, amount)
          budget.credited_amount - budget.debited_amount - amount
        end

        def append(actor:, budget:, entry_kind:, amount:, operation_key:, reason:)
          entry = budget.entries.create!(
            account_public_id: budget.account.public_id, user_public_id: budget.user_public_id,
            entry_sequence: budget.last_entry_sequence + 1, kind: entry_kind,
            amount: amount, cost_unit: budget.account.cost_unit,
            actor_public_id: actor.public_id, reason: reason, operation_key: operation_key
          )
          head = entry_kind == "credit_adjustment" ? :credited_amount : :debited_amount
          budget.update!(
            head => budget.public_send(head) + amount,
            last_entry_sequence: entry.entry_sequence
          )
          Result.new(outcome: :adjusted, entry: entry)
        end
    end
  end
end
