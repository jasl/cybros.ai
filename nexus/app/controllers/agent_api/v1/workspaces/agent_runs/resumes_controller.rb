class AgentAPI::V1::Workspaces::AgentRuns::ResumesController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    lifecycle(AgentRuns::Resume)
  end
end
