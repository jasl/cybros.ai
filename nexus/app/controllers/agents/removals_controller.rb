class Agents::RemovalsController < Agents::BaseController
  # The steward's own copy of the record-management verb: both Agent credential
  # planes end immediately; related work stops asynchronously.
  def create
    outcome = Users::Remove.call(user: agent_profile)
    RealtimeConnections::Disconnect.user_authority(agent_profile) if outcome == :removed
    notice = outcome == :removed ? t(".removed") : t(".unavailable")
    redirect_to agent_path(agent_profile), notice: notice
  end
end
