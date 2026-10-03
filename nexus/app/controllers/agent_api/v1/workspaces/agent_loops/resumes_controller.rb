class AgentAPI::V1::Workspaces::AgentLoops::ResumesController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    lifecycle(AgentLoops::Resume)
  end
end
