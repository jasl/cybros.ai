# THE APPROVER'S VERBS: any principal with write standing on the
# workspace, the agent acting for its person included.
class AgentAPI::V1::Workspaces::Runs::Tasks::ApprovesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Approve)
  end
end
