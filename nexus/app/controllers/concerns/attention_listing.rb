module AttentionListing
  private

    def attention_page
      @attention_view = params.fetch(:view, "actionable").to_s
      runs = case @attention_view
      when "actionable" then Run.writable_by(acting_user, workspace: selected_workspace)
      when "following" then Run.visible_to(acting_user, workspace: selected_workspace)
      else raise APIErrors::ParameterInvalid, :view
      end
      scope = Run::AvailableActions.attention_tasks(runs: runs)
        .select("tasks.*", "runs.public_id AS run_public_id")
        .includes(:sources, :addressed_executor, :target_executor, :mcp_connection, :approved_by_user,
          run: [:workspace, :variant, { turn: [:conversation, :answering_user] }])
      # Task keys are unique inside their Run; together with the Run UUID
      # they provide a public, stable cursor without exposing database ids.
      keyset_page(scope, columns: { run_public_id: :uuid, node_key: :text },
        expressions: { run_public_id: Run.arel_table[:public_id] })
    end
end
