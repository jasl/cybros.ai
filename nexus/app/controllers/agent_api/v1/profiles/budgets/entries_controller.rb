class AgentAPI::V1::Profiles::Budgets::EntriesController < AgentAPI::V1::Profiles::BudgetsController
  def index
    render_budget_entries
  end
end
