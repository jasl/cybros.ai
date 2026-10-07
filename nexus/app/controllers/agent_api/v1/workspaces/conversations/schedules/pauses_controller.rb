class AgentAPI::V1::Workspaces::Conversations::Schedules::PausesController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  def create = transition(:pause)
end
