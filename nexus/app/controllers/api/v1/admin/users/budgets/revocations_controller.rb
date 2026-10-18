class API::V1::Admin::Users::Budgets::RevocationsController < API::V1::Admin::Users::BudgetsController
  def create
    revoke_budget
  end
end
