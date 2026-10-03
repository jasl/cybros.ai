module CybrosAgent
  module Api
    # Typed projections of the Workspace family: Basic for list items, Full for singular
    # answers, and named owner/creator values rather than untyped hashes. `dedicated` is the
    # only public dedication marker — no exact agent identifier ever crosses this surface.

    WorkspaceOwnerSummary = Data.define(:public_id, :display_name) do
      include Redacted

      def inspect = redacted(public_id:, display_name:)
    end

    # One override entry as the Full projection renders it: the
    # provider's public id is the workspace's own snapshot, so it is always
    # present; `display_name` and `assignment_scope` are resolved from the
    # provider at read time and are nil once it is reaped — the read still
    # names the id, and that family's calls fail `tool_not_served`.
    ToolProviderOverride = Data.define(:provider_public_id, :display_name, :assignment_scope)

    WorkspaceCreatorSummary = Data.define(:public_id, :display_name, :kind) do
      include Redacted

      def inspect = redacted(public_id:, display_name:, kind:)
    end

    WorkspaceSummary = Data.define(
      :public_id, :name, :access_mode, :state, :dedicated,
      :lock_version, :archived_at, :created_at, :updated_at
    ) do
      include Redacted

      def inspect
        redacted(public_id:, name:, access_mode:, state:, dedicated:, lock_version:, archived_at:,
                 created_at:, updated_at:)
      end
    end

    # The Full projection. `metadata` is application-owned JSON that may carry
    # credentials, so every diagnostic redacts it — read it through the
    # accessor, never through inspect. `tool_provider_overrides` is the
    # override map keyed by namespace (`{"nexus.memory" => ToolProviderOverride}`,
    # `{}` when nothing is overridden): frozen like metadata, but shown —
    # it names a provider, never a secret.
    Workspace = Data.define(
      :public_id, :name, :access_mode, :state, :dedicated,
      :lock_version, :archived_at, :created_at, :updated_at,
      :metadata, :tool_provider_overrides, :owner, :creator
    ) do
      include Redacted

      def inspect
        redacted(public_id:, name:, access_mode:, state:, dedicated:, lock_version:, archived_at:,
                 created_at:, updated_at:, tool_provider_overrides:, owner:, creator:, hidden: %i[metadata])
      end
    end

    # One principal as the member plane lists it: the key a
    # conversation's access carrier takes, the handle it takes in the key's
    # place (`@handle`), the kind, the words a person reads, and —
    # for an agent — the identifier its program connected under and the
    # Human it answers to (nil for a Human on both).
    Principal = Data.define(:public_id, :handle, :kind, :display_name, :agent_identifier, :steward_public_id) do
      include Redacted

      def agent? = kind == "agent"
      def human? = kind == "human"
      def inspect = redacted(public_id:, handle:, kind:, display_name:, agent_identifier:, steward_public_id:)
    end
  end
end
