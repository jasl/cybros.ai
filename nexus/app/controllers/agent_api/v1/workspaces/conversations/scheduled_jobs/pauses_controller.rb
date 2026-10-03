class AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::PausesController <
      AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::BaseController
  def create = transition(:pause)
end
