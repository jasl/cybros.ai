class AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::ResumesController <
      AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::BaseController
  def create = transition(:resume)
end
