class Agents::CredentialsController < Agents::BaseController
  # The kill switch a steward owns for their own program: it stops
  # authenticating now on both planes, its delivery address ends with it, and
  # the profile stays connectable.
  def destroy
    agent_profile.revoke_connection
    RealtimeConnections::Disconnect.user_authority(agent_profile)
    redirect_to agent_path(agent_profile), notice: t(".revoked")
  end
end
