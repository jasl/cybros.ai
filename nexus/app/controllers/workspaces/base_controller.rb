# The signed-in Human's Workspace surface: reads resolve inside the
# effective-access relation. Management pre-guards the active-owner rule for the
# friendly path; every service re-checks in its own lock.
class Workspaces::BaseController < ApplicationController
  private

    def workspace
      @workspace ||= Workspace.data_accessible_to(Current.user).browsable.find_by!(
        public_id: params[:workspace_public_id] || params[:public_id]
      )
    end

    def ensure_manageable
      unless workspace.manageable_by?(Current.user)
        redirect_to workspace_path(workspace), alert: t("workspaces.not_owner")
      end
    end

    # Console forms carry their own render-time lock_version, so a mangled
    # value needs no 400 contract: it simply reads as a stale CAS.
    def command_lock_version
      params.expect(command: [:lock_version])[:lock_version].to_i
    end

    # Post-commit, best-effort completion: v1's trivially satisfied
    # descendant contracts usually complete the transition before the
    # redirected read, while the recurring sweep owns correctness.
    def complete_transition_after(result)
      if result.outcome == :accepted
        ::Workspaces::CompleteTransition.call(workspace: result.workspace)
      end
    end
end
