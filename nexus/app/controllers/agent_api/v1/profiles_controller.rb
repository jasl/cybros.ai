# GET /agent_api/v1/profile — the member plane's bootstrap read: a fenced credential is 401, never an
# empty block; unshipped blocks are absent, not "unavailable". No delivery-address block: the member
# plane never projects executor identity.
class AgentAPI::V1::ProfilesController < AgentAPI::V1::BaseController
  serves_plane :member

  def show
    credential = current_credential

    render json: AgentAPI::ProfilePresenter.full(
      member: credential.user, credential: credential, measured_at: Time.current
    )
  end
end
