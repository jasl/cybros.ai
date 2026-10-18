class Conversations::SchedulesController < Conversations::BaseController
  include ScheduleListing
  include AgentAPI::KeysetPagination

  before_action :set_job, only: :show

  def index
    @page = keyset_page(filtered_schedules(@conversation.schedules).including_context, columns: { public_id: :uuid })
    @schedules = @page.records
    @projections = ::Schedules::Projection.many(@schedules, by: acting_user).index_by { |row| row.fetch(:public_id) }
    @read_at = Time.current
    render "schedules/index"
  end

  def show
    @projection = ::Schedules::Projection.full(@job, by: acting_user)
    @read_at = Time.current
  end

  private

    def set_job
      @job = @conversation.schedules.including_context.find_by!(public_id: params.fetch(:id))
    end

    def list_direction
      params[:order].blank? ? :desc : super
    end
end
