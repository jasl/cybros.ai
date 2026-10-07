module Workspaces
  # WHOLE REPLACEMENT of one column under the workspace's CAS: the provider
  # override opt-in. Write standing under the dedication fence, not
  # ownership — the design's line, and the reason an agent with write
  # standing may opt its workspace in. The provider checks are READS before
  # any lock: a provider revoked between this read and the commit fails its
  # calls `tool_not_served` — level-triggered, exactly the
  # announcement-drift rule. The commit is the fact; `lock_version` CASes
  # as the metadata PATCH does, so a concurrent PATCH answers `stale`
  # rather than being silently overwritten.
  class SetToolProviderOverrides
    include Mutation

    class << self
      def call(...)
        new(...).call
      end
    end

    # `overrides`: a Hash of String → String, shaped by the controller.
    def initialize(workspace:, by:, overrides:, lock_version:)
      @workspace = workspace
      @by = by
      @overrides = overrides
      @lock_version = lock_version
    end

    def call
      refusal = lock_free_refusal
      return Mutation::Result.blocked(refusal) if refusal

      # No Humans-only set: the caller may be an agent with write standing.
      with_mutation_locks(@workspace, []) do |locked, _humans|
        standing = locked.write_refusal(@by)
        if standing
          Mutation::Result.blocked(standing)
        else
          locked.lock_version = @lock_version
          locked.tool_provider_overrides = @overrides
          locked.save ? Mutation::Result.done(:updated, locked) : Mutation::Result.invalid(locked)
        end
      end
    end

    private

      # ONE code on both doors: the announcement door refuses a reserved
      # namespace `reserved_namespace`, and so does this one. A key that is
      # neither reserved nor overridable is the model's to name (`:invalid`).
      def lock_free_refusal
        @overrides.each do |namespace, provider_public_id|
          return :reserved_namespace if Nexus::ToolRegistry::RESERVED_NAMESPACES.include?(namespace)

          provider = TaskExecutor.find_by(account_id: @workspace.account_id, public_id: provider_public_id)
          return :provider_not_eligible unless eligible_provider?(provider)
          return :provider_incomplete unless serves_namespace_whole?(provider, namespace)
        end
        nil
      end

      # A live tools provider of the account whose scope darkens no member:
      # addressing requires `eligible_for?(principal)`, whose machine arm is
      # `account_wide? || manager == the principal's controlling Human`, and
      # a private workspace's principals are its owner and that owner's
      # agents — so a `user_private` provider is admitted only there, and
      # only under the owner.
      def eligible_provider?(provider)
        return false if provider.nil? || !provider.tool_provider? || provider.revoked?

        provider.account_wide? || (@workspace.private? && @workspace.owner_id == provider.manager_id)
      end

      # The completeness rule, names only (never the profile): every live
      # wire name of the namespace, or two memories under one family.
      def serves_namespace_whole?(provider, namespace)
        Nexus::ToolRegistry.wire_names_in(namespace).all? { |name| provider.served?(name) }
      end
  end
end
