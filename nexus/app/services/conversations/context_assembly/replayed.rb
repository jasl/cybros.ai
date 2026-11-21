module Conversations
  class ContextAssembly
    # THE REPLAY, LANDED WHERE HISTORY IS BUILT: every candidate that holds
    # replay material is decided ONCE by the ladder against the target and
    # carries the decision into the fit, priced as the provider counts it.
    # Reasoning is history — it rides with its turn and leaves only with it —
    # so nothing here cuts a trace; the fit (ChatHistory) cuts turns.
    module Replayed
      module_function

      # Answers `[segments, reasons]`: the segments with every decision
      # landed, and the ladder's word for each trace it could not land (the
      # degradations a log line reports). `last_turn` decides only the newest
      # eligible segment; `none` decides nothing.
      def decide(segments, replay:, profile:)
        eligible = segments.each_index.select { |index| eligible?(segments[index]) }
        eligible = eligible.last(1) if replay.mode == "last_turn"
        reasons = []
        decided = eligible.to_h do |index|
          decision = ModelReasoning::ReplayLadder.call(trace: segments[index].trace, target: replay.target)
          reasons << decision.reason if decision.reason
          [index, decision]
        end
        landed = segments.each_with_index.map do |segment, index|
          decision = decided[index]
          decision ? land(segment, decision, profile) : segment
        end
        price_claude_handoffs(landed, decided, replay.target, profile)
        [landed, reasons]
      end

      # A signed block and its later handoff both consume context. Charge the
      # copy to the source segment: when the window drops it, both costs go.
      def price_claude_handoffs(segments, decisions, target, profile)
        return unless target.capability.format == "anthropic_thinking" && target.reasoning_enabled != false

        lowest_reader = ModelReasoning::ClaudeHandoff.rank(target.provider_id, target.model_id)
        return unless lowest_reader

        segments.each_index.reverse_each do |index|
          segment = segments[index]
          trace = segment.trace
          next unless segment.role == "assistant" && trace&.origin_format_variant == "anthropic_thinking"
          producer = ModelReasoning::ClaudeHandoff.producer_rank(trace.origin_provider_id, trace.origin_model_id)
          next unless producer

          decision = decisions[index]
          if producer > lowest_reader && %i[native_parts placed_parts].include?(decision&.kind)
            texts = decision.payloads.filter_map { |payload| ModelReasoning::PortableSummary.from_payload(payload, origin: trace.native_origin) }
            cost = texts.sum { |text| FillCost.call(text, profile) }
            segments[index] = segment.with(replay_tokens: segment.replay_tokens + cost)
          end
          reader = ModelReasoning::ClaudeHandoff.rank(trace.origin_provider_id, trace.origin_model_id)
          lowest_reader = [lowest_reader, reader].min if reader
        end
      end

      # A turn is eligible only when its trace holds replay material —
      # reasoning or a signed call: a trace that carries nothing but the
      # answer's markers and the provider's verdict on the replayed history
      # must not take the last turn's slot from an older turn that thought.
      def eligible?(segment) = segment.role == "assistant" && segment.trace&.replay_material?

      # The decision lands INTO the placement RoundReplay's walk made, never
      # a second ordering: Placement's own boundary rule splits the native
      # items — before the round's first marker they lead the message, the
      # rest join the placed tail at their ordinals; a signed call replaces
      # its original wherever it was placed, by value; parts land on the
      # host message. The landed segment carries what it costs.
      def land(segment, decision, profile)
        segment = sign_calls(segment, decision) if decision.call_payloads.any?
        if !segment.pairs_only && (decision.message_payloads.any? || decision.kind == :placed_parts && segment.trace.message_markers.any?)
          segment = place_message_blocks(segment, decision)
        end
        landed = case decision.kind
        when :native_parts
          parts = decision.payloads.map do |payload|
            Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, payload: payload,
              native_origin: segment.trace.native_origin)
          end
          segment.with(reasoning_parts: segment.reasoning_parts + parts)
        when :native_item, :placed_parts
          placed = decision.placed_items(segment.trace.native_origin)
          leading, later = Runs::RoundReplay::Placement.split(placed, segment.first_slot)
          segment.with(reasoning_items: segment.reasoning_items + leading,
            trailing: Runs::RoundReplay::Placement.merge(segment.trailing, later))
        when :summary
          segment.with(parts: decision.summary_parts + segment.parts)
        when :drop then segment
        else raise ArgumentError, "unknown replay decision #{decision.kind}"
        end
        landed.with(replay_tokens: cost(segment.trace, decision, profile))
      end

      # A native blob is priced by its CAPTURED accounting — the provider's
      # own count, the only honest number for opaque material and for a
      # signed block whose text is a summary of what it bills; else the
      # landed texts ride the same fill math as everything else. Nothing
      # landed costs nothing.
      def cost(trace, decision, profile)
        # Ordinary summary parts are already priced alongside the answer.
        return 0 if decision.kind == :summary || !decision.replayed?

        captured = trace.reasoning_items.sum { |item| item["reasoning_tokens"].to_i }
        return captured if captured.positive?

        decision.payloads.flat_map { |payload| landed_texts(payload) }.sum { |text| FillCost.call(text, profile) }
      end

      def landed_texts(payload)
        [payload["thinking"], payload["text"]].compact +
          (Array(payload["summary"]) + Array(payload["content"])).filter_map { |part| part["text"] } +
          Array(payload["blocks"]).filter_map { |block| block["text"] }
      end

      def sign_calls(segment, decision)
        origin = segment.trace.native_origin
        signed = segment.call_items.map do |item|
          payload = decision.call_payloads[item.payload.fetch("call_id")]
          payload ? item.with_native_payload(payload, origin: origin) : item
        end
        by_original = segment.call_items.zip(signed).to_h
        segment.with(call_items: signed,
          trailing: segment.trailing.map { |ordinal, element| [ordinal, by_original.fetch(element, element)] })
      end

      def place_message_blocks(segment, decision)
        trace = segment.trace
        # A direct reply carries its words on the host. A loop history has
        # already placed the ordinary messages among calls at their ordinals.
        ordinary = segment.trailing.filter_map { |_ordinal, element| element if element in Nexus::TextInputMessage }
        text = ordinary.any? ? Nexus::ModelRequestInput.text_segments(ordinary).join : segment.texts.join
        messages = Runs::RoundReplay::Placement.block_messages(trace, text, decision.message_payloads)
        first_slot = segment.first_slot || trace.markers.map { |item| item.fetch("ordinal") }.min
        ordinals = messages.map(&:first)
        remaining = segment.trailing.reject { |ordinal, _| ordinals.include?(ordinal) }
        segment.with(parts: [], first_slot: first_slot,
          trailing: Runs::RoundReplay::Placement.merge(remaining, messages))
      end
    end
  end
end
