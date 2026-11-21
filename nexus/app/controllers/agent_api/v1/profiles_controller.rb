# GET /agent_api/v1/profile — the member plane's bootstrap read: a fenced credential is 401, never an
# empty block; unshipped blocks are absent, not "unavailable". No delivery-address block: the member
# plane never projects executor identity.
# @auth [MemberBearer]
class AgentAPI::V1::ProfilesController < AgentAPI::V1::BaseController
  serves_plane :member

  # @oas_include
  # @summary Read profiles
  # @tags Member, profiles
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1ProfilesShow
  def show
    credential = current_credential

    render json: AgentAPI::ProfilePresenter.full(
      member: credential.user, credential: credential, measured_at: Time.current
    )
  end
end
