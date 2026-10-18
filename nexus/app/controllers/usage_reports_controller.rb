class UsageReportsController < Work::BaseController
  def show
    @workspace = selected_workspace
    @agent = if params[:agent_public_id].present?
      current_account.users.where(kind: :agent).find_by!(public_id: params.expect(:agent_public_id))
    end
    now = Time.current
    @analysis = WorkReports::Analysis.call(user: acting_user, workspace: @workspace, agent: @agent,
      from: now - 7.days, to: now).report
    @return_to = return_path(params[:return_to])
  end
end
