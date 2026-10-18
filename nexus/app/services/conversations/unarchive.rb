module Conversations
  # Blanket-clears `archived_at` over the whole subagent tree, sound
  # because followers are never independently archivable. Tombstoned rows stay concealed.
  class Unarchive
    def self.call(...) = new(...).call

    def initialize(conversation:)
      @conversation = conversation
    end

    def call
      @conversation.with_lock do
        next Outcome.refused(:not_found) if @conversation.tombstoned?
        next Outcome.refused(:subagent_follows_parent) if @conversation.subagent?
        next Outcome.refused(:side_conversation) if @conversation.side?

        # The sides the archive reaped are gone; nothing resurrects them.
        Conversation
          .where(id: SubagentTree.member_ids(@conversation), tombstoned_at: nil)
          .where.not(archived_at: nil)
          .update_all(archived_at: nil, updated_at: Time.current)
        Outcome.accepted(@conversation)
      end
    end
  end
end
