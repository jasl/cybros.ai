module UsageBudgets
  # Creates one explicit-window budget and its initial grant atomically. Authority is rechecked
  # under the global lock order, the User lock serializes overlap checking, and the
  # target-scoped key makes a committed open replayable.
  class Open
    Result = Data.define(:outcome, :budget) do
      def opened? = outcome == :opened
      def not_authorized? = outcome == :not_authorized
      def invalid? = outcome == :invalid
      def unit_unconfigured? = outcome == :unit_unconfigured
      def overlap? = outcome == :overlap
      def conflict? = outcome == :conflict
    end

    # One normalized request, so the private steps take a value instead of a
    # seven-name parameter list.
    Request = Data.define(:actor, :target, :starts_at, :expires_at, :amount,
                          :operation_key, :reason)

    class << self
      def call(actor:, target:, starts_at:, amount:, operation_key:, expires_at: nil, reason: nil)
        amount = UsageBudgets.exact_nonnegative(amount)
        if amount.nil? || starts_at.nil? ||
            (expires_at && expires_at <= starts_at) ||
            !UsageBudgets.valid_operation_key?(operation_key) ||
            !UsageBudgets.valid_reason?(reason)
          return refuse(:invalid)
        end
        # Normalized to the column's precision at the boundary, or an exact
        # retry phantom-conflicts forever on a sub-microsecond clock.
        return refuse(:not_authorized) unless authorized?(actor: actor, target: target)

        open_within_transaction(Request.new(
          actor: actor, target: target,
          starts_at: UsageBudgets.at_column_precision(starts_at),
          expires_at: UsageBudgets.at_column_precision(expires_at),
          amount: amount, operation_key: operation_key, reason: reason
        ))
      rescue ActiveRecord::RecordNotUnique
        # A revoked window reopened at the same instant is an identity
        # collision, not an overlap; caught outside the transaction, which
        # the statement error already aborted.
        refuse(:starts_at_taken)
      end

      private

        def open_within_transaction(request)
          User.transaction do
            lock_principals(actor: request.actor, target: request.target)
            unless authorized?(actor: request.actor, target: request.target)
              next refuse(:not_authorized)
            end

            unit = request.target.account.cost_unit
            next refuse(:unit_unconfigured) if unit.nil?

            replay = find_replay(target: request.target, operation_key: request.operation_key)
            next replay_outcome(replay, request) if replay

            open_budget(request, unit: unit)
          end
        end

        def refuse(outcome) = Result.new(outcome: outcome, budget: nil)

        def authorized?(actor:, target:)
          return false unless actor.human? && actor.active?

          if target.agent_member?
            target.steward_id == actor.id
          elsif target.human? && !target.removed?
            actor.admin?
          else
            false
          end
        end

        # The global lock order: the Agent target first when present, then
        # every affected Human by ascending id. lock! reloads in place, so
        # the authority recheck above reads locked rows.
        def lock_principals(actor:, target:)
          PrincipalLocks.descend(target, actor)
        end

        # A committed open is its budget plus initial grant; the entry row IS
        # the recorded payload, so replay comparison needs no operation table.
        def find_replay(target:, operation_key:)
          UsageBudgetEntry.find_by(
            usage_budget_id: target.usage_budgets.select(:id),
            kind: "initial_grant", operation_key: operation_key
          )
        end

        def replay_outcome(entry, request)
          budget = entry.usage_budget
          exact = budget.starts_at == request.starts_at &&
            budget.expires_at == request.expires_at &&
            entry.amount == request.amount && entry.reason == request.reason
          exact ? Result.new(outcome: :opened, budget: budget) : refuse(:conflict)
        end

        def open_budget(request, unit:)
          target = request.target
          budget = target.usage_budgets.build(
            account: target.account, user_public_id: target.public_id,
            user_kind: target.kind, starts_at: request.starts_at,
            expires_at: request.expires_at,
            credited_amount: request.amount, last_entry_sequence: 1
          )
          unless budget.valid?
            overlap = budget.errors.of_kind?(:starts_at, :overlaps_usable_window)
            return refuse(overlap ? :overlap : :invalid)
          end
          budget.save!
          budget.entries.create!(
            account_public_id: target.account.public_id, user_public_id: target.public_id,
            entry_sequence: 1, kind: "initial_grant", amount: request.amount, cost_unit: unit,
            actor_public_id: request.actor.public_id, reason: request.reason,
            operation_key: request.operation_key
          )
          Result.new(outcome: :opened, budget: budget)
        end
    end
  end
end
