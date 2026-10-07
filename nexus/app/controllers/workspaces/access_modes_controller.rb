# The owner's access switch: the commit is the entire authority cut.
# Stale re-renders the workspace page in place, preserving the submitted
# selection against the current row.
class Workspaces::AccessModesController < Workspaces::BaseController
  before_action :ensure_manageable

  def update
    submitted = params.expect(access_mode: [:access_mode, :lock_version])
    result = ::Workspaces::UpdateAccessMode.call(
      workspace: workspace,
      by: Current.user,
      to: submitted[:access_mode].to_s,
      lock_version: submitted[:lock_version].to_i
    )

    case result.outcome
    when :updated
      redirect_to workspace_path(workspace), notice: t(".updated")
    when :stale_object
      render_workspace_in_place(submitted[:access_mode].to_s, status: :conflict,
        alert: t("workspaces.changed_elsewhere"))
    when :invalid
      render_workspace_in_place(submitted[:access_mode].to_s, status: :unprocessable_entity,
        alert: t(".invalid"))
    when :workspace_not_active
      redirect_to workspace_path(workspace), alert: t("workspaces.not_active")
    when :not_workspace_owner
      redirect_to workspace_path(workspace), alert: t("workspaces.not_owner")
    when :not_found
      raise ActiveRecord::RecordNotFound
    else
      raise "unmapped workspace outcome: #{result.outcome.inspect}"
    end
  end

  private

    def render_workspace_in_place(selection, status:, alert:)
      @workspace = workspace.reload
      @access_mode_selection = selection
      flash.now[:alert] = alert
      render "workspaces/show", status: status
    end
end
