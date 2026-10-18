class API::V1::Agents::Budgets::EntriesController < API::V1::Agents::BudgetsController
  def index
    render_budget_entries
  end
end
