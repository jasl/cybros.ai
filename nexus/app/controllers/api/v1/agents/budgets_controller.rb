class API::V1::Agents::BudgetsController < API::V1::BaseController
  include API::V1::AgentReading
  include BudgetReading, BudgetWriting

  before_action :load_readable_agent

  private

    def budget_target = @agent
end
