class Admin::AgentsController < Admin::BaseController
  PAGE_SIZE = 25
  SEARCH_QUERY_MAX_LENGTH = 100

  def index
    @query = params.permit(:query).fetch(:query, "").to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    @status = params[:status].to_s.presence_in(%w[active removed])
    agents = Current.account.users.members.where(kind: :agent).matching_name_or_handle(@query)
    agents = agents.where(status: @status) if @status
    @agents_pagy, @agents = pagy(
      :offset,
      agents.includes(:steward).order_by_display_name,
      limit: PAGE_SIZE
    )
  end

  def show
    @member = Current.account.users.members.where(kind: :agent).find_by!(public_id: params[:id])
  end
end
