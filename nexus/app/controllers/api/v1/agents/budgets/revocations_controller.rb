class API::V1::Agents::Budgets::RevocationsController < API::V1::Agents::BudgetsController
  def create
    revoke_budget
  end
end
