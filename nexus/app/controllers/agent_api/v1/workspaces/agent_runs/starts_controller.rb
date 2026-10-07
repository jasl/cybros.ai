class AgentAPI::V1::Workspaces::AgentRuns::StartsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    lifecycle(AgentRuns::Start)
  end
end
