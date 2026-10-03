class AgentAPI::V1::Workspaces::AgentLoops::Tasks::AbandonsController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    adjudicate(AgentLoops::Tasks::Abandon)
  end
end
