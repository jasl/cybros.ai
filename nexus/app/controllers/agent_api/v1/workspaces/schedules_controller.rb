# The workspace's scheduled jobs across its conversations: the overview a
# person reads before opening a job's own conversation. Rows reach the
# caller through the one conversation funnel the nested list uses, so a
# conversation the caller cannot read contributes nothing.
class AgentAPI::V1::Workspaces::SchedulesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include ScheduleListing

  def index
    scope = filtered_schedules(Schedule.visible_to(acting_user, workspace: @workspace)).including_context
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { schedules: ::Schedules::Projection.many(page.records, by: acting_user, workspace: @workspace),
      pagination: { next_after: page.next_after } }
  end
end
