class Attention::RunsController < Attention::BaseController
  include Work::RunCollection

  def index
    @workspace = selected_workspace
    @workspaces = browsable_workspaces.order(:name, :id)
    @fixed_attention = true
    @list_path = attention_runs_path
    @list_title = t("resource_management.attention_runs")
    @list_description = t("resource_management.attention_runs_description")
    prepare_run_collection(Run.visible_to(acting_user, workspace: @workspace).where.not(attention_reason: nil))
    render "run_listings/index"
  end
end
