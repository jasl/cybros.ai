# `{force: false}` (default) is graceful — in-flight work finishes and
# applies; `{force: true}` aborts running model steps NOW and they
# re-queue for resume (the old interrupt, absorbed).
class AgentAPI::V1::Workspaces::AgentLoops::PausesController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    lifecycle(AgentLoops::Pause, force: force_param)
  end
end
