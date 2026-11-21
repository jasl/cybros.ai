# The approver's refusal: `reason` is text or nothing — the detail the
# model reads back.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::DeniesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create denies
  # @tags Member, denies
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksDeniesCreate
  def create
    reason = params[:reason]
    raise APIErrors::ParameterInvalid, :reason unless reason.nil? || String.try_convert(reason)

    adjudicate(Runs::Tasks::Deny, reason: reason)
  end
end
