class Workspaces::RunsController < Work::BaseController
  include Work::RunCollection

  def index
    @workspace = browsable_workspaces.find_by!(public_id: params.fetch(:workspace_public_id))
    @workspace_work = true
    @list_path = workspace_runs_path(@workspace)
    @list_title = t("work_console.runs")
    @list_description = t("work_console.runs_description")
    prepare_run_collection(Run.visible_to(acting_user, workspace: @workspace), default_kind: "standalone")
    render "run_listings/index"
  end
end
