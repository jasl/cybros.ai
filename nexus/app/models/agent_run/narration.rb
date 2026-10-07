class AgentRun
  # Buffered to the end of the transaction so the event cursor — the last
  # rung of the lock ladder — is the last lock taken and one change is one
  # envelope; flushed from `before_commit` on the two rows every narration saves.
  class Narration
    BUFFER = :agent_run_narration_buffer

    class << self
      def record(agent_run, items)
        return if items.empty?

        source = source_identity(agent_run)
        items = items.map { |item| item.merge(payload: item.fetch(:payload).merge(source)) }
        transaction = ApplicationRecord.current_transaction
        return append(agent_run.host, items) unless transaction.open?

        buffer << { transaction: transaction, agent_run: agent_run, items: items }
        transaction.after_rollback { discard(transaction) }
      end

      # Everything still standing, in the order it was recorded, grouped
      # per HOST so two loops narrating onto one conversation land as one
      # envelope with contiguous sequences. Called once per participating
      # record; the first call drains and the rest find nothing.
      def flush
        pending = buffer
        return if pending.empty?

        ActiveSupport::IsolatedExecutionState[BUFFER] = []
        pending.group_by { |entry| entry[:agent_run].host }.each do |host, entries|
          append(host, entries.flat_map { |entry| entry[:items] })
        end
      end

      private

        # A delivered loop can keep narrating after another turn or variant
        # starts. Capture the writer's immutable seam before host grouping;
        # the conversation's displayed variant is not the source of this work.
        def source_identity(agent_run)
          identity = { "run_public_id" => agent_run.public_id }
          return identity if agent_run.standalone?

          identity.merge(
            "turn_public_id" => agent_run.conversation_turn.public_id,
            "variant_public_id" => agent_run.conversation_turn_variant.public_id
          )
        end

        def buffer = (ActiveSupport::IsolatedExecutionState[BUFFER] ||= [])

        def discard(transaction)
          ActiveSupport::IsolatedExecutionState[BUFFER] = buffer.reject { |entry| entry[:transaction] == transaction }
        end

        # A fresh key every time: a loop-locked appender never holds a
        # conversation host's row, so it never replays by product.
        def append(host, items)
          ConversationEvent::Append.call(host: host, items: items)
        end
    end
  end
end
