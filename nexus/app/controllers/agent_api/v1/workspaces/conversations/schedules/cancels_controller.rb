class AgentAPI::V1::Workspaces::Conversations::Schedules::CancelsController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  def create = transition(:cancel)
end
