class API::V1::Admin::Users::BudgetsController < API::V1::Admin::BaseController
  include BudgetReading, BudgetWriting

  private

    def budget_target
      @budget_target ||= Current.account.users.where(kind: "human").find_by!(public_id: params.fetch(:user_public_id))
    end
end
