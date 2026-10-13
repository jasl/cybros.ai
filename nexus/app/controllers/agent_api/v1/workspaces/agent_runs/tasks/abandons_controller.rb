class AgentAPI::V1::Workspaces::AgentRuns::Tasks::AbandonsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    adjudicate(AgentRuns::Tasks::Abandon)
  end
end
