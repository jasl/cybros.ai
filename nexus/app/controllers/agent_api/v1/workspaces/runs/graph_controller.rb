# The picture of a run — nodes, edges and a Mermaid flowchart — readable
# whole so a person can debug a loop and a UI can draw it. Reading is the
# only verb: the graph grows through tasks alone.
class AgentAPI::V1::Workspaces::Runs::GraphController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def show
    run = find_listable_loop(@workspace)
    render json: AgentAPI::RunGraphPresenter.call(run).to_h
  end
end
