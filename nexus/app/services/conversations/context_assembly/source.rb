module Conversations
  class ContextAssembly
    # WHAT THE BLOCKS READ FROM: the room, and the conversation when there
    # is one. A Conversation is its own source. A STANDALONE loop has no
    # conversation: history is empty (no timeline), memory is the
    # workspace's and the principal's own `user/` rung (no spawned-child
    # rule, no conversation rows), the `character` slot and `{{workspace}}`
    # are the room's. One value, so the slot, memory and history blocks
    # serve a standalone seed through the same code that serves a turn —
    # never a second assembly path. Every block and the facade take either a
    # Conversation or a Source under the one keyword (`Source.of`).
    Source = Data.define(:workspace, :conversation) do
      class << self
        def of(host)
          case host
          when Source then host
          when Conversation then new(workspace: host.workspace, conversation: host)
          else raise ArgumentError, "a Conversation or a Source, not #{host.inspect}"
          end
        end

        def standalone(workspace) = new(workspace: workspace, conversation: nil)
      end

      def workspace_id = workspace.id
      def conversation_id = conversation&.id
      def timeline = conversation&.timeline
      def standalone? = conversation.nil?

      # Public-id snapshots keep the classification after parent or job reaping.
      def conversation_kind
        if standalone?
          "standalone"
        elsif conversation.side?
          "side"
        elsif conversation.scheduled_execution?
          "scheduled"
        elsif conversation.subagent?
          "child"
        else
          "conversation"
        end
      end

      # Whose controlling Human the `user/` rung resolves to: the
      # conversation's rule (a spawned child's answerer), else the poster —
      # a standalone loop's creator.
      def memory_principal(poster) = conversation ? conversation.memory_principal(poster) : poster
    end
  end
end
