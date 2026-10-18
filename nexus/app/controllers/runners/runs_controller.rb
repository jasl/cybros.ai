class Runners::RunsController < Work::BaseController
  include Work::RunCollection

  def index
    @runner = Current.user.managed_executors.find_by!(public_id: params.fetch(:runner_public_id))
    @workspace = selected_workspace
    @workspaces = browsable_workspaces.order(:name, :id)
    @list_path = runner_runs_path(@runner)
    @list_title = t("resource_management.runner_runs", name: @runner.display_name)
    @list_description = t("runner_resources.related_work_scope")
    prepare_run_collection(Run.visible_to(acting_user, workspace: @workspace), fixed_executor: @runner)
    render "run_listings/index"
  end
end
