module WorkScope
  private

    def browsable_workspaces
      Workspace.data_accessible_to(acting_user).browsable
    end

    def selected_workspace
      if params[:workspace_public_id].present?
        @selected_workspace ||= browsable_workspaces.find_by!(public_id: params.expect(:workspace_public_id))
      end
    end
end
