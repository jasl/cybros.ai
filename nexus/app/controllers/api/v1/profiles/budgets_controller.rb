class API::V1::Profiles::BudgetsController < API::V1::BaseController
  include BudgetReading

  private

    def budget_target = Current.user
end
