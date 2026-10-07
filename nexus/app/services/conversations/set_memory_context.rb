module Conversations
  class SetMemoryContext
    def self.call(conversation:, acting_user:, memory_context:)
      return Outcome.refused(:not_authorized) unless conversation.writable_by?(acting_user)

      conversation.with_lock do
        next Outcome.refused(:not_found) if conversation.tombstoned?
        next Outcome.refused(:conversation_archived) if conversation.archived?
        next Outcome.accepted(conversation) if conversation.memory_context == memory_context

        conversation.memory_context = memory_context
        unless conversation.valid?
          next Outcome.invalid(conversation)
        end
        context = MemoryDocuments::Context.new(workspace: conversation.workspace,
          conversation: conversation, principal: acting_user, configuration: conversation.memory_context)
        next Outcome.refused(:memory_scope_unavailable) unless context.sources_available?

        conversation.note_context_change
        Outcome.accepted(conversation)
      end
    end
  end
end
