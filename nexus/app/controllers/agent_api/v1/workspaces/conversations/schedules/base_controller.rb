class AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  private

    def find_schedule
      find_listable_conversation(@workspace).schedules.find_by!(public_id: params.fetch(:schedule_public_id))
    end

    def transition(command)
      render_schedule(::Schedules::Manage.transition(find_schedule, command, by: acting_user))
    end

    def render_schedule(result)
      if result.accepted?
        render json: { schedule: ::Schedules::Projection.full(result.value, by: acting_user) }
      else
        render_refused(result)
      end
    end
end
