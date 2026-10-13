# An administrator opens a windowed virtual balance for a Human member — the
# hard stop behind priced admission — and ADJUSTS one (an attributed credit
# or debit appended atomically with the head update). The Idempotency-Key is
# the operation key on both: an exact replay returns the standing row, a
# divergent one conflicts.
class API::V1::Admin::Users::BudgetsController < API::V1::Admin::BaseController
  include API::V1::Admin::BudgetRendering

  def create
    key = required_operation_key or return
    target = find_target
    fields = params.expect(budget: [:amount, :starts_at, :expires_at, :reason])
    result = UsageBudgets::Open.call(
      actor: Current.user,
      target: target,
      amount: fields[:amount],
      starts_at: parse_time(fields[:starts_at], :starts_at),
      expires_at: fields[:expires_at].nil? ? nil : parse_time(fields[:expires_at], :expires_at),
      operation_key: key,
      reason: fields[:reason]
    )
    render_open_result(result, target)
  end

  # `PATCH …/budgets/{public_id}` with `{budget: {kind: credit | debit, amount,
  # reason?}}`: a credit is always legal (including deficit repair after the
  # budget window closes); a debit past the remaining headroom refuses.
  def update
    key = required_operation_key or return
    target = find_target
    budget = find_budget(target)
    fields = params.expect(budget: [:kind, :amount, :reason])
    result = UsageBudgets::Adjust.call(
      actor: Current.user, budget: budget, kind: fields[:kind].to_s.presence&.to_sym,
      amount: fields[:amount], operation_key: key, reason: fields[:reason]
    )
    render_adjust_result(result, target, budget)
  end

  private

    def render_open_result(result, target)
      case result.outcome
      when :opened
        # An exact replay returns :opened with the standing budget — the
        # command's own idempotency contract — so 201 serves both.
        render json: { budget: budget_projection(result.budget) }, status: :created
      when :not_authorized
        render_target_refusal(target)
      when :invalid
        render_refusal(:invalid, "Amount or window is invalid")
      else
        render_refusal(result.outcome)
      end
    end

    def render_adjust_result(result, target, budget)
      case result.outcome
      when :adjusted
        render json: { budget: budget_projection(budget.reload), entry: entry_projection(result.entry) }
      when :not_authorized
        render_target_refusal(target)
      when :invalid
        render_refusal(:invalid, "Kind, amount or reason is invalid")
      else
        render_refusal(result.outcome)
      end
    end

    # The appended entry, so a replay reads the same row it wrote.
    def entry_projection(entry)
      {
        sequence: entry.entry_sequence,
        kind: entry.kind,
        amount: entry.amount.to_s("F"),
        reason: entry.reason,
        operation_key: entry.operation_key,
        created_at: entry.created_at,
      }
    end
end
