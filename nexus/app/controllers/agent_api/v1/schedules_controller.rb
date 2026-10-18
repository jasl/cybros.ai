class AgentAPI::V1::SchedulesController < AgentAPI::V1::Workspaces::BaseController
  include ScheduleListing

  def index
    scope = filtered_schedules(Schedule.visible_to(acting_user, workspace: selected_workspace)).including_context
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { schedules: ::Schedules::Projection.many(page.records, by: acting_user),
      pagination: { next_after: page.next_after } }
  end
end
