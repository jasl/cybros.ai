module Workspaces
  # active -> archiving: removes the Workspace from live lists and blocks
  # new writes at commit while preserving browsable reads.
  class Archive < AcceptLifecycle
    private

      def accepted_states
        %w[active]
      end

      def already_current_state
        "archived"
      end

      def accept(locked)
        locked.accept_archive
      end
  end
end
