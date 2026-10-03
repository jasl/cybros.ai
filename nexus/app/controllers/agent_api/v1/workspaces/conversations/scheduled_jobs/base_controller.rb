class AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::BaseController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  private

    def find_scheduled_job
      find_listable_conversation(@workspace).scheduled_jobs.find_by!(public_id: params.fetch(:scheduled_job_public_id))
    end

    def transition(command)
      result = ::ScheduledJobs::Manage.transition(find_scheduled_job, command, by: acting_user)
      if result.accepted?
        render json: { scheduled_job: AgentAPI::ScheduledJobPresenter.full(result.value, by: acting_user) }
      else
        render_refused(result)
      end
    end
end
