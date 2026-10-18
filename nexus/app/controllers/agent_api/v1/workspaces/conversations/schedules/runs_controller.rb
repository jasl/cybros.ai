class AgentAPI::V1::Workspaces::Conversations::Schedules::RunsController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  def create = render_schedule(::Schedules::Manage.run_now(find_schedule, by: acting_user))
end
