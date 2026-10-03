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
        [landed, reasons]
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
        landed = case decision.kind
        when :native_parts
          parts = decision.payloads.map do |payload|
            Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, payload: payload,
              native_origin: segment.trace.native_origin)
          end
          segment.with(reasoning_parts: segment.reasoning_parts + parts)
        when :native_item
          placed = decision.ordinals.zip(decision.payloads).map do |ordinal, payload|
            [ordinal, Nexus::ReasoningInputItem.new(type: "reasoning_item", payload: payload,
              native_origin: segment.trace.native_origin)]
          end
          leading, later = AgentLoops::RoundReplay::Placement.split(placed, segment.first_slot)
          segment.with(reasoning_items: segment.reasoning_items + leading,
            trailing: AgentLoops::RoundReplay::Placement.merge(segment.trailing, later))
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
        return 0 unless decision.replayed?

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
    end
  end
end
