# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::DefaultRunnersController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::DefaultRunnerSelection

  # @oas_include
  # @summary Update default runners
  # @tags Member, default runners
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsDefaultRunnersUpdate
  def update
    run = find_listable_loop(@workspace)
    return render_refusal(:conversation_hosted) unless run.standalone?

    select_default_runner(run)
  end

  private

    def render_selected_host(run)
      render json: { run: AgentAPI::RunPresenter.full(run.reload) }
    end
end
