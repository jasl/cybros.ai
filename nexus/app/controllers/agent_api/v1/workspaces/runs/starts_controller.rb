class AgentAPI::V1::Workspaces::Runs::StartsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    lifecycle(Runs::Start)
  end
end
