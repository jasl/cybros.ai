class Agents::BudgetsController < Agents::BaseController
  include BudgetPages

  private

    def budget_target = agent
    def budget_back_path = agent_path(@budget_target)
    def budget_route_parameters = { controller: "/agents/budgets", agent_public_id: @budget_target.public_id }
end
