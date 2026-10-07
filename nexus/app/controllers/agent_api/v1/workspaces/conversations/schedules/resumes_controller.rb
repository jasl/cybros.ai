class AgentAPI::V1::Workspaces::Conversations::Schedules::ResumesController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  def create = transition(:resume)
end
