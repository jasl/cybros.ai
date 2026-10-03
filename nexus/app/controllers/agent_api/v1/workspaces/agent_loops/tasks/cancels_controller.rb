# The person-side branch cancel: the call key the model saw, or any branch
# node; 409 `not_a_branch` for the spine.
class AgentAPI::V1::Workspaces::AgentLoops::Tasks::CancelsController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    adjudicate(AgentLoops::CancelBranch)
  end
end
