module Workspaces
  # The three lifecycle commands' skeleton: owner-only, one
  # current-state edge, optimistic CAS, immediate authority commit.
  class AcceptLifecycle
    include Mutation

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:, by:, lock_version:)
      @workspace = workspace
      @by = by
      @lock_version = lock_version
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
        elsif accepted_states.include?(locked.state)
          locked.lock_version = @lock_version
          accept(locked)
          Mutation::Result.done(:accepted, locked)
        elsif locked.state == already_current_state
          # A state-based no-op still answers with the current row (the
          # frozen public contract renders it as a 200 projection).
          Mutation::Result.done(:state_already_current, locked)
        else
          Mutation::Result.blocked(:transition_in_progress)
        end
      end
    end
  end
end
