module AgentAPI
  # Plain-Ruby projection: Basic for lists, Full for singular responses.
  # `dedicated` is the only public dedication marker — the exact agent
  # identifier never renders on any public surface.
  class WorkspacePresenter
    class << self
      def basic(workspace)
        {
          public_id: workspace.public_id,
          name: workspace.name,
          access_mode: workspace.access_mode,
          state: workspace.state,
          dedicated: !workspace.agent_identifier.nil?,
          lock_version: workspace.lock_version,
          archived_at: workspace.archived_at,
          created_at: workspace.created_at,
          updated_at: workspace.updated_at,
        }
      end

      # Full carries the override map keyed by namespace, mirroring the
      # write: the provider's `display_name` and `assignment_scope` beside
      # its id so a person can see why a call is served — or refused. A
      # reaped provider renders nils beside its id (the snapshot outlives
      # it); a revoked one renders its name while its calls fail `tool_not_served`.
      def full(workspace)
        basic(workspace).merge(
          metadata: workspace.metadata,
          tool_provider_overrides: tool_provider_overrides(workspace),
          owner: {
            public_id: workspace.owner.public_id,
            display_name: workspace.owner.display_name,
          },
          creator: {
            public_id: workspace.creator.public_id,
            display_name: workspace.creator.display_name,
            kind: workspace.creator.kind,
          },
        )
      end

      private

        def tool_provider_overrides(workspace)
          workspace.tool_provider_overrides.to_h do |namespace, public_id|
            provider = TaskExecutor.find_by(account_id: workspace.account_id, public_id: public_id)
            [namespace, {
              provider_public_id: public_id,
              display_name: provider&.display_name,
              assignment_scope: provider&.assignment_scope,
            }]
          end
        end
    end
  end
end
