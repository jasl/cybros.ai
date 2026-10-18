class Admin::Users::Budgets::RevocationsController < Admin::Users::BudgetsController
  def create
    revoke_budget
  end
end
