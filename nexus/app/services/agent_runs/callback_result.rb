module AgentRuns
  # The exact independent worker answer used by ResultDelivery. Requester identity is a
  # fact of the original request, never inferred from the callback's author.
  module CallbackResult
    module_function

    def for(child:, turn:, variant:, scheduled: false)
      return unless turn.input_public_id && variant

      { "conversation_public_id" => child.public_id, "input_public_id" => turn.input_public_id,
        "turn_public_id" => turn.public_id, "variant_public_id" => variant.public_id,
        "requester_speaker_public_id" => requester(child, turn, variant, scheduled: scheduled) }
    end

    def requester(child, turn, variant, scheduled:)
      job = child.schedule if scheduled
      if job&.source_run_public_id
        # Dispatch froze this occurrence's voice. Later schedule edits cannot
        # change its requester, even if the creating execution was pruned.
        return turn.speaker.public_id if turn.speaker.kind == "ingress"

        source = AgentRun.find_by(public_id: job.source_run_public_id)
        source && for_loop(source)
      elsif job
        original_speaker(turn)
      else
        source_id = SourceWork.source_of(variant)
        source = AgentRun.find_by(public_id: source_id) if source_id
        source_id ? source && for_loop(source) : original_speaker(turn)
      end
    end

    def for_loop(source)
      # Ownership is immutable and points to an older execution at each step.
      while source
        variant = source.conversation_turn_variant
        return unless variant

        turn = variant.conversation_turn
        unless turn.callback_sources.empty?
          requesters = turn.callback_sources.map { |item| item.fetch("result").fetch("requester_speaker_public_id") }.uniq
          return requesters.first if requesters.one?
          return
        end
        source_id = SourceWork.source_of(variant)
        return original_speaker(turn) unless source_id

        source = AgentRun.find_by(public_id: source_id)
      end
    end

    def original_speaker(turn)
      return if turn.compaction_summary? || ConversationInput::KERNEL_ORIGINS.include?(turn.origin)

      turn.speaker.public_id
    end
  end
end
