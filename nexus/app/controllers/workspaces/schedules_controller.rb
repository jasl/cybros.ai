class Workspaces::SchedulesController < Work::BaseController
  include ScheduleListing
  include AgentAPI::KeysetPagination

  def index
    @workspace = browsable_workspaces.find_by!(public_id: params.fetch(:workspace_public_id))
    scope = filtered_schedules(Schedule.visible_to(acting_user, workspace: @workspace)).including_context
    @page = keyset_page(scope, columns: { public_id: :uuid })
    @schedules = @page.records
    @projections = ::Schedules::Projection.many(@schedules, by: acting_user).index_by { |row| row.fetch(:public_id) }
    @read_at = Time.current
    render "schedules/index"
  end

  private

    def list_direction
      params[:order].blank? ? :desc : super
    end
end
