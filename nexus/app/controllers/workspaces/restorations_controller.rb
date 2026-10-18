# Restore acceptance: live access returns at commit and the flash says
# accepted; completion to active is post-commit and owned by the recurring
# sweep. Input-free, so stale recovery is plain PRG.
class Workspaces::RestorationsController < Workspaces::BaseController
  before_action :ensure_manageable

  def create
    result = ::Workspaces::Restore.call(
      workspace: workspace, by: Current.user, lock_version: command_lock_version
    )
    complete_transition_after(result)

    case result.outcome
    when :accepted
      redirect_to workspace_path(workspace), notice: t(".accepted")
    when :state_already_current
      redirect_to workspace_path(workspace), notice: t(".already_active")
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
