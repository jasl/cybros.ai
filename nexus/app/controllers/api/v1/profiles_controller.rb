# Introspection for the presented credential: the acting member and the
# credential's plane (null for sessions). Platform-plane only, so never an
# executor binding.
# @auth [PlatformBearer, BrowserSession]
class API::V1::ProfilesController < API::V1::BaseController
  # @oas_include
  # @summary Read profiles
  # @tags Platform, profiles
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1ProfilesShow
  def show
    member = Current.user

    render json: {
      member: {
        public_id: member.public_id,
        kind: member.kind,
        role: member.role,
      },
      credential_plane: Current.access_token&.credential_plane,
    }
  end
end
