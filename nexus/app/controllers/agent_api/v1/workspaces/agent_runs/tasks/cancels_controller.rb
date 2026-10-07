# The person-side branch cancel: the call key the model saw, or any branch
# node; 409 `not_a_branch` for the mainline.
class AgentAPI::V1::Workspaces::AgentRuns::Tasks::CancelsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    adjudicate(AgentRuns::CancelBranch)
  end
end
