class Agents::RestorationsController < Agents::BaseController
  def create
    outcome = agent_profile.restore
    notice = outcome == :restored ? t(".restored") : t(".unavailable")
    redirect_to agent_path(agent_profile), notice: notice
  end
end
