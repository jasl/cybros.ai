class AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::CancelsController <
      AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::BaseController
  def create = transition(:cancel)
end
