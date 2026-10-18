class AgentAPI::V1::Workspaces::Conversations::Schedules::ExecutionsController <
      AgentAPI::V1::Workspaces::Conversations::Schedules::BaseController
  def index
    job = find_schedule
    scope = Conversation.visible_to(acting_user, workspace: @workspace).where(schedule_id: job.id)
    page = keyset_page(scope, columns: { public_id: :uuid })
    projected = ::Schedules::ExecutionProjection.call(page.records.map(&:id))
    last_cursor = page.records.last && encode_cursor(page.records.last, [:public_id], list_direction)
    render json: { executions: page.records.map { |child| projected.fetch(child.id) },
      pagination: { next_after: page.next_after, last_cursor: last_cursor || params[:after] } }
  end
end
