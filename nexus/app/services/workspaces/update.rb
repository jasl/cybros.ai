module Workspaces
  # Owner-authorized optimistic rename/metadata update. An omitted keyword
  # leaves that attribute untouched; explicit nil is assigned and validated.
  # Non-lifecycle management requires the active state.
  class Update
    include Mutation

    # Field presence survives below the controller: an omitted keyword
    # means "leave unchanged", while an explicit nil is a real assignment
    # that model validation then judges.
    UNSET = Object.new.freeze

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:, by:, lock_version:, name: UNSET, metadata: UNSET)
      @workspace = workspace
      @by = by
      @lock_version = lock_version
      @name = name
      @metadata = metadata
    end

    def call
      # kind is create-frozen, so a non-Human actor is rejected before any
      # lock and the winner's locked set stays Humans-only.
      return Mutation::Result.blocked(:not_workspace_owner) unless @by.human?

      with_mutation_locks(@workspace, [@by]) do |locked, humans|
        actor = humans[@by.id]

        if locked.tombstoned?
          Mutation::Result.blocked(:not_found)
        elsif actor.nil? || !locked.manageable_by?(actor)
          Mutation::Result.blocked(:not_workspace_owner)
        elsif !locked.active?
          Mutation::Result.blocked(:workspace_not_active)
        else
          locked.lock_version = @lock_version
          locked.name = @name unless @name.equal?(UNSET)
          locked.metadata = @metadata unless @metadata.equal?(UNSET)

          if locked.save
            Mutation::Result.done(:updated, locked)
          else
            Mutation::Result.invalid(locked)
          end
        end
      end
    end
  end
end
