module AgentAPI
  class WorkspaceMessagingPresenter
    class << self
      def full(workspace)
        {
          agents: workspace.messaging_policy.agents.map do |entry|
            {
              agent_public_id: entry.agent_public_id,
              mode: entry.mode,
              allowed_sender_public_ids: entry.allowed_sender_public_ids,
            }
          end,
          lock_version: workspace.lock_version,
        }
      end
    end
  end
end
