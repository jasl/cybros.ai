module Workspaces
  # Ownership transfer: attribution never follows, a private transfer
  # ends the losing side's access at commit and cancels its work in the
  # same transaction; account-wide cancels nothing.
  class TransferOwnership
    include Mutation

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:, by:, to:, lock_version:)
      @workspace = workspace
      @by = by
      @to = to
      @lock_version = lock_version
    end

    def call
      # kind is create-frozen: a non-Human actor or target is rejected before
      # any lock, keeping the winner's locked set Humans-only.
      return Mutation::Result.blocked(:not_workspace_owner) unless @by.human?
      return Mutation::Result.blocked(:target_not_eligible) unless @to.human?

      authority_changed = false
      result = with_mutation_locks(@workspace, [@by, @to]) do |locked, humans|
        actor = humans[@by.id]
        target = humans[@to.id]

        if locked.tombstoned?
          Mutation::Result.blocked(:not_found)
        elsif actor.nil? || !locked.manageable_by?(actor)
          Mutation::Result.blocked(:not_workspace_owner)
        elsif target.nil? || !target.active? ||
            target.account_id != locked.account_id || target.id == actor.id
          # Self-transfer is domain-rejected so no crafted request can render
          # a false successful transfer.
          Mutation::Result.blocked(:target_not_eligible)
        elsif !locked.active?
          Mutation::Result.blocked(:workspace_not_active)
        else
          # A private Workspace's access relation IS its owner, so the new
          # owner's arrival ends the old one's access. An account-wide
          # Workspace ends nobody's and bypasses cancellation discovery.
          previously = locked.dup
          locked.lock_version = @lock_version
          locked.update!(owner: target)
          if previously.private?
            ModelInvocation::Cancellation.call(
              scope: locked.model_work_losing_access(previously: previously),
              reason: "workspace_access_revoked"
            )
            authority_changed = true
          end
          Mutation::Result.done(:transferred, locked)
        end
      end

      disconnect_realtime_workspace_authority(result.workspace) if authority_changed
      result
    end
  end
end
