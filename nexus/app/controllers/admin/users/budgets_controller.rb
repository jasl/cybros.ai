class Admin::Users::BudgetsController < Admin::BaseController
  include BudgetPages

  private

    def budget_target
      Current.account.users.where(kind: "human").find_by!(public_id: params.fetch(:user_id))
    end

    def budget_back_path = admin_user_path(@budget_target)
    def budget_route_parameters = { controller: "/admin/users/budgets", user_id: @budget_target.public_id }
end
