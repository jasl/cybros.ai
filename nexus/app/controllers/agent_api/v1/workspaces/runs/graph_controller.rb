# The picture of a run — nodes, edges and a Mermaid flowchart — readable
# whole so a person can debug a loop and a UI can draw it. Reading is the
# only verb: the graph grows through tasks alone.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::GraphController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read graph
  # @tags Member, graph
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsGraphShow
  # @response_ref (410) #/components/responses/APIError
  def show
    run = find_listable_loop(@workspace)
    render json: AgentAPI::RunGraphPresenter.call(run).to_h
  end
end
