module BudgetReading
  extend ActiveSupport::Concern
  include AgentAPI::KeysetPagination

  def index
    target = budget_target
    measured_at = Time.current
    current = target.usage_budgets.usable_at(measured_at).includes(:account).first
    page = keyset_page(target.usage_budgets.includes(:account), columns: { starts_at: :timestamp, public_id: :uuid })
    render json: {
      user_public_id: target.public_id, user_kind: target.kind, cost_unit: target.account.cost_unit,
      measured_at: measured_at,
      current_budget: current && budget_projection(current, at: measured_at),
      budgets: page.records.map { |budget| budget_projection(budget, at: measured_at) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    measured_at = Time.current
    render json: { budget: budget_projection(find_budget, at: measured_at), measured_at: measured_at }
  end

  private

    def find_budget
      budget_target.usage_budgets.includes(:account).find_by!(
        public_id: params[:budget_public_id] || params.fetch(:public_id)
      )
    end

    def budget_projection(budget, at: Time.current) = UsageBudgets::Projection.budget(budget, at: at)

    def render_budget_entries
      page = keyset_page(find_budget.entries, columns: { entry_sequence: :integer })
      render json: {
        entries: page.records.map { |entry| UsageBudgets::Projection.entry(entry) },
        pagination: { next_after: page.next_after },
      }
    end
end
