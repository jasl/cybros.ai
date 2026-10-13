class Agents::RestorationsController < Agents::BaseController
  def create
    outcome = agent.restore
    notice = outcome == :restored ? t(".restored") : t(".unavailable")
    redirect_to agent_path(agent), notice: notice
  end
end
