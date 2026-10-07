# Introspection for the presented credential: the acting member and the
# credential's plane (null for sessions). Platform-plane only, so never an
# executor binding.
class API::V1::ProfilesController < API::V1::BaseController
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
