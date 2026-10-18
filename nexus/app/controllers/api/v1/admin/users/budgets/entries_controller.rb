class API::V1::Admin::Users::Budgets::EntriesController < API::V1::Admin::Users::BudgetsController
  def index
    render_budget_entries
  end
end
