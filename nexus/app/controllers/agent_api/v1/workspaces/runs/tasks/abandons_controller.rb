class AgentAPI::V1::Workspaces::Runs::Tasks::AbandonsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Abandon)
  end
end
