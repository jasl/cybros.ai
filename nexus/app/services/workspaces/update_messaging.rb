module Workspaces
  # One owner-authorized replacement. The Workspace's ordinary optimistic
  # version detects competing edits; existing work is not canceled or rewritten.
  class UpdateMessaging
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(workspace:, by:, agents:, lock_version:)
      @workspace = workspace
      @by = by
      @agents = agents
      @lock_version = lock_version
    end

    def call
      if @workspace.tombstoned?
        Mutation::Result.blocked(:not_found)
      elsif !@workspace.manageable_by?(@by)
        Mutation::Result.blocked(:not_workspace_owner)
      elsif !@workspace.active?
        Mutation::Result.blocked(:workspace_not_active)
      else
        @workspace.lock_version = @lock_version
        @workspace.messaging_policy = { agents: @agents }
        # PUT must check its version even when it matches this loaded snapshot.
        @workspace.messaging_policy_will_change!

        if @workspace.save
          Mutation::Result.done(:updated, @workspace)
        else
          Mutation::Result.invalid(@workspace)
        end
      end
    rescue ActiveRecord::StaleObjectError
      Mutation::Result.blocked(:stale_object)
    end
  end
end
