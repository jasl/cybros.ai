module Workspaces
  # The commit is the whole authority cut: every access answer reads the current
  # relation. Narrowing also cancels work whose principal loses access, in this
  # transaction; widening cancels nothing.
  class UpdateAccessMode
    include Mutation

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:, by:, to:, lock_version:)
      @workspace = workspace
      @by = by
      @to = to.to_s
      @lock_version = lock_version
    end

    def call
      # kind is create-frozen, so a non-Human actor is rejected before any
      # lock and the winner's locked set stays Humans-only.
      return Mutation::Result.blocked(:not_workspace_owner) unless @by.human?
      unless Workspace.access_modes.key?(@to)
        return Mutation::Result.blocked(:invalid_access_mode)
      end

      authority_narrowed = false
      result = with_mutation_locks(@workspace, [@by]) do |locked, humans|
        actor = humans[@by.id]

        if locked.tombstoned?
          Mutation::Result.blocked(:not_found)
        elsif actor.nil? || !locked.manageable_by?(actor)
          Mutation::Result.blocked(:not_workspace_owner)
        elsif !locked.active?
          Mutation::Result.blocked(:workspace_not_active)
        else
          # The relation before this command, so the cut is the difference:
          # widening and a same-mode retry end nobody's access.
          previously = locked.dup
          locked.lock_version = @lock_version
          locked.access_mode = @to

          if locked.save
            if previously.account_wide? && locked.private?
              ModelInvocation::Cancellation.call(
                scope: locked.model_work_losing_access(previously: previously),
                reason: "workspace_access_revoked"
              )
              authority_narrowed = true
            end
            Mutation::Result.done(:updated, locked)
          else
            Mutation::Result.invalid(locked)
          end
        end
      end

      disconnect_realtime_workspace_authority(result.workspace) if authority_narrowed
      result
    end
  end
end
