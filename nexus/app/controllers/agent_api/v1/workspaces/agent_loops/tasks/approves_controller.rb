# THE APPROVER'S VERBS: any principal with write standing on the
# workspace, the agent application acting for its person included.
class AgentAPI::V1::Workspaces::AgentLoops::Tasks::ApprovesController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    adjudicate(AgentLoops::Tasks::Approve)
  end
end
