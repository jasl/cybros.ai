# THE APPROVER'S VERBS: any principal with write standing on the
# workspace, the agent application acting for its person included.
class AgentAPI::V1::Workspaces::AgentRuns::Tasks::ApprovesController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    adjudicate(AgentRuns::Tasks::Approve)
  end
end
