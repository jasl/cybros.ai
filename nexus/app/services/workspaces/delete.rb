module Workspaces
  # Every surface disappears at commit and the retention clock starts; a tombstone
  # answers not_found, so a repeat has nothing to reach.
  class Delete < AcceptLifecycle
    def call
      result = super
      disconnect_realtime_workspace_authority(result.workspace) if result.outcome == :accepted
      result
    end

    private

      def accepted_states
        %w[active archived]
      end

      def already_current_state
        nil
      end

      def accept(locked)
        locked.accept_delete
      end
  end
end
