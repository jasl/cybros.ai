class AgentAPI::V1::Profiles::BudgetsController < AgentAPI::V1::BaseController
  include BudgetReading

  serves_plane :member

  private

    def budget_target = Current.user
end
