# The three budget doors' shared HTTP half: the required operation key, the
# one projection, and the target-side refusal — the gate already owns
# `administrator_required`, so a service's `:not_authorized` can only be
# about the TARGET (an Agent member whose steward is someone else, a
# removed Human), and the plane's word for that is removals'
# `user_not_administrable`.
module API::V1::Admin::BudgetRendering
  extend ActiveSupport::Concern

  private

    # The Idempotency-Key IS the ledger's operation key on every budget
    # write; a missing one is 400 before any read, and nil so the action
    # returns.
    def required_operation_key
      key = request.headers["Idempotency-Key"]
      return key if key.present?

      render_error(:idempotency_key_required, "Idempotency-Key header is required", status: :bad_request)
      nil
    end

    def find_target
      User.find_by!(public_id: params.fetch(:user_public_id))
    end

    # The member PATCH names the row `:public_id`; the nested revocation
    # command names it `:budget_public_id` — one finder, under the target.
    def find_budget(target)
      target.usage_budgets.find_by!(public_id: params[:budget_public_id] || params.fetch(:public_id))
    end

    def render_target_refusal(target)
      render_refusal(:not_authorized,
        ("An Agent member's budget is administered by its current steward" if target.agent_member?))
    end

    def budget_projection(budget)
      {
        public_id: budget.public_id,
        user_public_id: budget.user_public_id,
        credited_amount: budget.credited_amount.to_s("F"),
        debited_amount: budget.debited_amount.to_s("F"),
        cost_unit: budget.account.cost_unit,
        starts_at: budget.starts_at,
        expires_at: budget.expires_at,
        revoked_at: budget.revoked_at,
      }
    end
end
