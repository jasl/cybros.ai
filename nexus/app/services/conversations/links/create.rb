module Conversations
  module Links
    class Create
      def self.call(...) = new(...).call

      # A linked spawn holds these same grant owners before its root/child
      # Conversation locks, then publishes the relation and brief together.
      def self.with_authority(workspace:, agents:)
        workspace.with_lock("FOR SHARE") do
          principals = User.where(id: agents.map(&:id)).order(:id).lock("FOR SHARE").to_a
          User.where(id: principals.map(&:steward_id).compact).order(:id).lock("FOR SHARE").load
          yield
        end
      end

      # Caller already owns Workspace, both Agents/current stewards and the
      # endpoint Conversations. A newborn child belongs to that transaction.
      # The caller narrates a new link after its remaining business locks.
      def self.call_locked(...) = new(...).create

      def initialize(conversation:, agent:, peer_conversation:, peer_agent:, acting_user:)
        @conversation, @agent = conversation, agent
        @peer_conversation, @peer_agent, @acting_user = peer_conversation, peer_agent, acting_user
      end

      def call
        return Outcome.refused(:not_found) unless @conversation.workspace_id == @peer_conversation.workspace_id

        self.class.with_authority(workspace: @conversation.workspace, agents: [@agent, @peer_agent]) do
          endpoints = Conversation.where(id: [@conversation.id, @peer_conversation.id])
            .order(:id).lock("FOR SHARE").index_by(&:id)
          @conversation = endpoints.fetch(@conversation.id)
          @peer_conversation = endpoints.fetch(@peer_conversation.id)
          result = create
          result.value.narrate(acting_user: @acting_user) if result.accepted? && result.value.previously_new_record?
          result
        end
      end

      def create
        return Outcome.refused(:not_found) unless @conversation.workspace_id == @peer_conversation.workspace_id
        return Outcome.refused(:validation_failed) if @conversation == @peer_conversation ||
          @conversation.side? || @peer_conversation.side?
        return Outcome.refused(:not_found) if @conversation.tombstoned? || @peer_conversation.tombstoned?
        return Outcome.refused(:not_authorized) unless
          @conversation.writable_by?(@acting_user) && @peer_conversation.writable_by?(@acting_user)

        workspace = @conversation.workspace
        pairs = [[@conversation, @agent.reload], [@peer_conversation, @peer_agent.reload]].sort_by { |endpoint, _| endpoint.id }
        return Outcome.refused(:conversation_archived) if pairs.any? { |endpoint, _| endpoint.archived? }
        return Outcome.refused(:answerer_not_eligible) unless pairs.all? { |endpoint, agent| endpoint.answerer_eligible?(agent) }
        return Outcome.refused(:messaging_not_allowed) unless
          workspace.messaging_allowed?(sender: @agent, recipient: @peer_agent) &&
            workspace.messaging_allowed?(sender: @peer_agent, recipient: @agent)

        first, second = pairs
        link = workspace.conversation_links.active.create_or_find_by!(
          first_conversation: first.first, first_agent: first.last,
          second_conversation: second.first, second_agent: second.last)
        Outcome.accepted(link)
      end
    end
  end
end
