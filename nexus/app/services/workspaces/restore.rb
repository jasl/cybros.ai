module Workspaces
  # archived -> restoring: returns live data access and new admission at
  # commit; truthfully canceled work is never resurrected.
  class Restore < AcceptLifecycle
    private

      def accepted_states
        %w[archived]
      end

      def already_current_state
        "active"
      end

      def accept(locked)
        locked.accept_restore
      end
  end
end
