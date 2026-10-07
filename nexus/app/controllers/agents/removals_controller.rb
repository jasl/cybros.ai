class Agents::RemovalsController < Agents::BaseController
  # The steward's own copy of the record-management verb: both Agent credential
  # planes end immediately; related work stops asynchronously.
  def create
    outcome = Users::Remove.call(user: agent)
    RealtimeConnections::Disconnect.user_authority(agent) if outcome == :removed
    notice = outcome == :removed ? t(".removed") : t(".unavailable")
    redirect_to agent_path(agent), notice: notice
  end
end
