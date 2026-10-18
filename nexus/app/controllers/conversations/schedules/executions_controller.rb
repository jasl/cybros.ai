class Conversations::Schedules::ExecutionsController < Conversations::Schedules::BaseController
  include AgentAPI::KeysetPagination

  def index
    scope = Conversation.visible_to(acting_user, workspace: @conversation.workspace).where(schedule_id: @job.id)
    @page = keyset_page(scope, columns: { public_id: :uuid })
    projected = ::Schedules::ExecutionProjection.call(@page.records.map(&:id))
    @executions = @page.records.map { |child| projected.fetch(child.id) }
    @read_at = Time.current
  end

  private

    def list_direction
      params[:order].blank? ? :desc : super
    end
end
