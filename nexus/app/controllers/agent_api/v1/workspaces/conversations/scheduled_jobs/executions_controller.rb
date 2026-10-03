class AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::ExecutionsController <
      AgentAPI::V1::Workspaces::Conversations::ScheduledJobs::BaseController
  def index
    job = find_scheduled_job
    scope = Conversation.visible_to(acting_user, workspace: @workspace).where(scheduled_job_id: job.id)
    page = keyset_page(scope, columns: { public_id: :uuid })
    projected = ::ScheduledJobs::ExecutionProjection.call(page.records.map(&:id))
    last_cursor = page.records.last && encode_cursor(page.records.last, [:public_id], list_direction)
    render json: { executions: page.records.map { |child| projected.fetch(child.id) },
      pagination: { next_after: page.next_after, last_cursor: last_cursor || params[:after] } }
  end
end
