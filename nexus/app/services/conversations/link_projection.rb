module Conversations
  module LinkProjection
    def self.call(link, conversation:)
      first = link.first_conversation_id == conversation.id
      endpoint_conversation, endpoint_agent, peer_conversation, peer_agent = first ?
        [link.first_conversation, link.first_agent, link.second_conversation, link.second_agent] :
        [link.second_conversation, link.second_agent, link.first_conversation, link.first_agent]
      {
        public_id: link.public_id, workspace_public_id: link.workspace.public_id,
        endpoint: { conversation_public_id: endpoint_conversation.public_id, agent_public_id: endpoint_agent.public_id },
        peer: { conversation_public_id: peer_conversation.public_id, agent_public_id: peer_agent.public_id },
        state: link.state, created_at: link.created_at, closed_at: link.closed_at, close_reason: link.close_reason,
      }
    end
  end
end
