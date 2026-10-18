class API::V1::Profiles::Budgets::EntriesController < API::V1::Profiles::BudgetsController
  def index
    render_budget_entries
  end
end
