class AgentAPI::V1::Workspaces::Runs::ResumesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    lifecycle(Runs::Resume)
  end
end
