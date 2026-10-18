# The person-side branch cancel: the call key the model saw, or any branch
# node; 409 `not_a_branch` for the mainline.
class AgentAPI::V1::Workspaces::Runs::Tasks::CancelsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    adjudicate(Runs::CancelBranch)
  end
end
