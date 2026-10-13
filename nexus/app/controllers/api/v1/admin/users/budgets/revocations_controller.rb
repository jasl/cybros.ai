# `POST …/budgets/{public_id}/revocation`: the single-transition freeze —
# new admissions stop, no entry already written moves. The Idempotency-Key
# is the stored `revoke_operation_key`: the same key with the same reason
# replays the standing row, a different key on a budget already revoked is
# `budget_already_revoked`, the same key with another reason conflicts.
class API::V1::Admin::Users::Budgets::RevocationsController < API::V1::Admin::BaseController
  include API::V1::Admin::BudgetRendering

  def create
    key = required_operation_key or return
    target = find_target
    budget = find_budget(target)
    reason = params.fetch(:revocation, {}).permit(:reason)[:reason]
    result = UsageBudgets::Revoke.call(actor: Current.user, budget: budget, operation_key: key, reason: reason)
    render_revoke_result(result, target, budget)
  end

  private

    def render_revoke_result(result, target, budget)
      case result.outcome
      when :revoked
        render json: { budget: budget_projection(budget.reload) }
      when :not_authorized
        render_target_refusal(target)
      when :invalid
        render_refusal(:invalid, "Key or reason is invalid")
      else
        render_refusal(result.outcome)
      end
    end
end
