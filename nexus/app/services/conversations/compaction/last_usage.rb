module Conversations
  module Compaction
    # OCCUPANCY DERIVES FROM THE LAST PROVIDER-REPORTED USAGE RECORD, never
    # from re-counting: ONE reader of "the newest number the provider gave
    # for this context", on both hosts. Mid-turn that is the round's mainline
    # source — the request this round's prefix replays; between turns it is
    # the newest turn that ran a model — a direct reply's own invocation, or
    # a loop-backed reply's newest mainline round. A summary turn's loop is a
    # branch and reports nothing, which is right: the summary reset the
    # context and the number before it is stale.
    module LastUsage
      # What the between-turn site needs beside the record: the position
      # after which the turns it did not count begin.
      Reading = Data.define(:record, :since_position)

      module_function

      # The mainline source's latest attempt, succeeded only — a failed first
      # try's empty numbers are not the context's size.
      def for_round(node, source: history_source(node))
        return nil if source.nil?

        succeeded(record_of(source.selected_model_invocation_id))
      end

      def for_conversation(conversation)
        variant = newest_reporting_variant(conversation)
        return nil if variant.nil?

        record = succeeded(record_of(invocation_id_of(variant)))
        return nil if record.nil?

        Reading.new(record: record, since_position: variant.conversation_turn.position)
      end

      # Silent truncation: a provider that quietly dropped the head
      # reports FEWER input tokens than the source it extended, by more
      # than the appended tail could explain. Evidence for a watcher,
      # never a trigger — "more than the tail" is the only rule the kernel
      # can state without picking a threshold. A repaired round replays
      # nothing of its source, so it is exempt.
      def truncation_suspected?(node, record)
        return false if record.nil? || record.input_tokens.nil? || node.repaired?

        source = history_source(node)
        previous = for_round(node, source: source)
        return false if previous.nil? || previous.input_tokens.nil?

        previous.input_tokens - record.input_tokens > tail_cost(node, source: source)
      end

      def history_source(node)
        return nil if node.arrived_summary

        AgentRuns::InputComposition.sources_for(node).find(&:model_task?)
      end

      def record_of(invocation_id)
        return nil if invocation_id.nil?

        invocation = ModelInvocation.find_by(id: invocation_id)
        invocation && UsageRecord.for_latest_attempt(invocation)
      end

      def succeeded(record)
        record if record&.succeeded?
      end

      # The newest variant that names a model, whatever its turn's kind:
      # the tail of what the provider last saw.
      def newest_reporting_variant(conversation)
        ConversationTurnVariant
          .joins(:conversation_turn)
          .where(conversation_turns: { conversation_id: conversation.id })
          .where.not(provider_id: nil)
          .order(id: :desc)
          .first
      end

      # A direct reply's own invocation, or the newest mainline round's of a
      # loop-backed one; a summary loop's mainline is empty.
      def invocation_id_of(variant)
        return variant.model_invocation_id if variant.model_invocation_id

        agent_run = variant.agent_run
        return nil if agent_run.nil?

        agent_run.mainline_nodes.where.not(selected_model_invocation_id: nil)
          .order(:id).last&.selected_model_invocation_id
      end

      # The bytes this round's sealed request appended past its source's,
      # at FillCost's rate — the tail is small, and the prefix is the
      # provider's own number.
      def tail_cost(node, source:)
        entries = node.invocation_body("request")&.content_body_entries.to_a
        replayed = source&.invocation_body("request")&.content_body_entries&.count.to_i
        entries.drop(replayed).sum do |entry|
          (Nexus::CanonicalJson.bytesize(entry.content_fragment.payload) / 4.0).ceil
        end
      end
    end
  end
end
