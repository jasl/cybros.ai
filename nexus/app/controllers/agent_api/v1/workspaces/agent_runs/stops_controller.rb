# `{force: true}` (default — stop means stop) terminalizes in-flight
# work; `{force: false}` is the graceful drain: running steps and
# parked awaits finish, nothing new starts, then the loop settles.
class AgentAPI::V1::Workspaces::AgentRuns::StopsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    lifecycle(AgentRuns::Stop, force: force_param(default: true))
  end
end
