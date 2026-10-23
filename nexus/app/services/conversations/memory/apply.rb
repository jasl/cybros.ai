module Conversations
  module Memory
    # A memory write changes the assembled context, so it owes what every
    # such write owes: the `context_revision` bump clients CAS on (under
    # the anchor's writer, `revises:`), and the conversation row lock, so
    # it cannot interleave with a fork copying its pointers. `by:` is the
    # acting User whose visibility applies to the selected bindings.
    # The anchor is resolved before any lock and its row locked
    # FIRST, in ladder order — users and workspaces rank above
    # conversations — then the conversation; for `conversation/` both are
    # one row, locked once. The loop verb (`Memory::Run#revising`) holds
    # the same two in the same order, so the two doors never cross.
    class Apply
      class << self
        # `description:` is a skill row's (a `skills/` path); the writer
        # refuses one on any other path and requires one on that.
        def write(conversation:, path:, content:, by:, expected:, description: nil, speaker: nil, expected_collection_public_id: nil)
          apply(conversation, path, by, speaker, expected_collection_public_id) do |anchor|
            result = MemoryDocuments::Write.call(
              anchor: anchor, content: content, expected: expected,
              revises: conversation, description: description
            )
            result.written? ? Outcome.accepted(result.document) : Outcome.refused(result.outcome)
          end
        end

        def edit(conversation:, path:, old_text:, new_text:, by:, expected:, speaker: nil, expected_collection_public_id: nil)
          apply(conversation, path, by, speaker, expected_collection_public_id) do |anchor|
            result = MemoryDocuments::Edit.call(anchor: anchor, old_text: old_text,
              new_text: new_text, expected: expected, revises: conversation)
            result.written? ? Outcome.accepted(result.document) : Outcome.refused(result.outcome)
          end
        end

        def delete(conversation:, path:, by:, expected:, speaker: nil, expected_collection_public_id: nil)
          apply(conversation, path, by, speaker, expected_collection_public_id) do |anchor|
            result = MemoryDocuments::Delete.call(anchor: anchor, expected: expected, revises: conversation)
            result.deleted? ? Outcome.accepted : Outcome.refused(result.outcome)
          end
        end

        private

          def apply(conversation, path, by, speaker, expected_collection_public_id)
            return Outcome.refused(:not_found) if conversation.tombstoned?
            return Outcome.refused(:conversation_archived) if conversation.archived?

            context = MemoryDocuments::Context.new(workspace: conversation.workspace,
              conversation: conversation, principal: by, configuration: conversation.effective_memory_context(speaker: speaker),
              agent: conversation.answering_agent)
            anchor = context.resolve(path, authoring: true)
            return Outcome.refused(anchor.refusal) unless anchor.resolved?

            context.with_locks(anchor) do
              next Outcome.refused(:not_found) if conversation.tombstoned?
              # Archived is read-only, like every other content verb here.
              next Outcome.refused(:conversation_archived) if conversation.archived?

              # The host lock orders binding changes. Never follow a changed
              # path to a different owner while holding the old owner's locks.
              current = MemoryDocuments::Context.new(workspace: conversation.workspace,
                conversation: conversation, principal: by, configuration: conversation.effective_memory_context(speaker: speaker),
                agent: conversation.answering_agent).resolve(path, authoring: true)
              next Outcome.refused(current.refusal) unless current.resolved?
              if current.collection.public_id != anchor.collection.public_id ||
                  (expected_collection_public_id && current.collection.public_id != expected_collection_public_id)
                next Outcome.refused(:stale_object)
              end

              yield(anchor)
            end
          end
      end
    end
  end
end
