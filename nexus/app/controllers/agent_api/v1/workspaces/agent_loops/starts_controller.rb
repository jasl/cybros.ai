class AgentAPI::V1::Workspaces::AgentLoops::StartsController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    lifecycle(AgentLoops::Start)
  end
end
