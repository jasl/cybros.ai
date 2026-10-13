# THE NESTED DOORS' ONE FINDER (idiom #6): every controller under
# `workspaces/:workspace_public_id/…` loads its workspace through the
# access graph before the action runs — no effective access and tombstones
# both read as absence, and the miss is the family 404 through the plane's
# `RecordNotFound` rescue. The member plane's own `WorkspacesController`
# addresses the row by `:public_id` and keeps its finder.
module AgentAPI::V1::WorkspaceScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_workspace
  end

  private

    def set_workspace
      @workspace = Workspace.data_accessible_to(acting_user).browsable
        .find_by!(public_id: params.fetch(:workspace_public_id))
    end
end
