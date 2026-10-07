# The picture of a run — nodes, edges and a Mermaid flowchart — readable
# whole so a person can debug a loop and a UI can draw it. Reading is the
# only verb: the graph grows through tasks alone.
class AgentAPI::V1::Workspaces::AgentRuns::GraphController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    agent_run = find_listable_loop(@workspace)
    render json: AgentAPI::AgentRunGraphPresenter.call(agent_run).to_h
  end
end
