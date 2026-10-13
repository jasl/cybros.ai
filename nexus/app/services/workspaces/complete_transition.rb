module Workspaces
  # Lock, recheck, advance exactly one edge; restart is rediscovery,
  # never replay.
  class CompleteTransition
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:)
      @workspace = workspace
    end

    def call
      # Completion serializes with owner commands on the Workspace row
      # alone: it consults no principal and carries no CAS, so a competing
      # acceptance simply changes what the recheck below finds.
      @workspace.with_lock do
        Mutation::Result.done(@workspace.complete_transition, @workspace)
      end
    end
  end
end
