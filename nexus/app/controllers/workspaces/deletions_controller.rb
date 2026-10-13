# Delete acceptance: every data and management surface disappears at
# commit, so success returns to the index — the tombstone would answer
# the show page with absence.
class Workspaces::DeletionsController < Workspaces::BaseController
  before_action :ensure_manageable

  def destroy
    result = ::Workspaces::Delete.call(
      workspace: workspace, by: Current.user, lock_version: command_lock_version
    )
    complete_transition_after(result)

    case result.outcome
    when :accepted
      redirect_to workspaces_path, notice: t(".accepted")
    when :stale_object
      redirect_to workspace_path(workspace), alert: t("workspaces.changed_elsewhere")
    when :transition_in_progress
      redirect_to workspace_path(workspace), alert: t("workspaces.transition_in_progress")
    when :not_workspace_owner
      redirect_to workspace_path(workspace), alert: t("workspaces.not_owner")
    when :not_found
      raise ActiveRecord::RecordNotFound
    else
      raise "unmapped workspace outcome: #{result.outcome.inspect}"
    end
  end
end
