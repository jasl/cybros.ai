class Settings::BudgetsController < Settings::BaseController
  include BudgetPages

  private

    def budget_target = Current.user
    def personal_budget? = true
    def budget_back_path = settings_profile_path
    def budget_route_parameters = { controller: "/settings/budgets" }
end
