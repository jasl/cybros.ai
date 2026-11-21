# How far a run has come — the authored phases in write order, the one in
# flight, the background work and the spend — derived from rows that
# already exist. Reading is the only verb. Named for what it answers
# (`phases`): `progress` is the executor plane's ephemeral feed, and one
# word carries one meaning on the wire.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::PhasesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Read phases
  # @tags Member, phases
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsPhasesShow
  # @response_ref (410) #/components/responses/APIError
  def show
    run = find_listable_loop(@workspace)
    render json: AgentAPI::RunPhasesPresenter.call(run).to_h
  end
end
