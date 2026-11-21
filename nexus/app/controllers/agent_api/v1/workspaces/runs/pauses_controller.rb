# `{force: false}` (default) is graceful — in-flight work finishes and
# applies; `{force: true}` aborts running model steps NOW and they
# re-queue for resume (the old interrupt, absorbed).
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::PausesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create pauses
  # @tags Member, pauses
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsPausesCreate
  # @response_ref (410) #/components/responses/APIError
  def create
    lifecycle(Runs::Pause, force: force_param)
  end
end
