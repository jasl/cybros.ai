class Agents::Budgets::RevocationsController < Agents::BudgetsController
  def create
    revoke_budget
  end
end
