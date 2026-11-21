module ModelReasoning
  # The per-turn replay ladder: the native shape where the target can read
  # the origin, otherwise a provider-supplied summary when switching models.
  class ReplayLadder
    Target = Data.define(:provider_id, :model_id, :reasoning_enabled, :capability)

    # kind: :native_parts (in-message blocks, or the chat message's field) |
    # :native_item (role-less items, one per replayed reasoning item) |
    # :placed_parts (interleaved thought parts) | :summary (assistant text) | :drop.
    # `ordinals` names the trace item each placed payload came from,
    # parallel to `payloads` (`[]` for the other kinds), so a renderer
    # places each where it was thought without re-deciding which items
    # replay. Call payloads have their own rung: a signature can ride
    # without any standalone reasoning, even when kind is :drop.
    Decision = Data.define(:kind, :payloads, :ordinals, :reason, :call_payloads, :message_payloads) do
      class << self
        def native_parts(payloads) = new(kind: :native_parts, payloads: payloads, reason: nil)

        # `placed` is `[[ordinal, payload], ...]` in trace order.
        def native_items(placed)
          new(kind: :native_item, payloads: placed.map(&:last), ordinals: placed.map(&:first), reason: nil)
        end

        def drop(reason) = new(kind: :drop, payloads: [], reason: reason)
      end

      def initialize(ordinals: [], call_payloads: {}, message_payloads: {}, **) = super

      def replayed? = kind != :drop || call_payloads.any? || message_payloads.any?

      # Native blocks at their original ordinals. Both Messages and
      # GenerateContent join adjacent assistant items into one turn.
      def placed_items(origin)
        case kind
        when :native_item
          ordinals.zip(payloads).map do |ordinal, payload|
            [ordinal, Nexus::ReasoningInputItem.new(type: "reasoning_item", payload: payload, native_origin: origin)]
          end
        when :placed_parts
          ordinals.zip(payloads).map do |ordinal, payload|
            part = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING, payload: payload, native_origin: origin)
            [ordinal, Nexus::TextInputMessage.new(role: "assistant", parts: [part])]
          end
        else []
        end
      end

      def summary_parts
        return [] unless kind == :summary

        payloads.map { |text| Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text) }
      end
    end

    # The formats a provider carries across its own models: Anthropic
    # accepts every block back and drops, silently and unbilled, what the
    # current model cannot read; Gemini accepts unsigned thought parts
    # across its models.
    CROSS_MODEL_FORMATS = %w[anthropic_thinking gemini_thought].freeze

    # The public Responses API preserves a same-family upgrade. The Codex
    # backend accepts both directions for these two models. Brokers with
    # the same model names have their own replay contracts.
    RESPONSES_NATIVE_SWITCHES = [
      %w[openai_api openai_responses gpt-6.2-sol gpt-6.2-astra].freeze,
      %w[codex_subscription codex_responses gpt-6.2-sol gpt-6.2-astra].freeze,
      %w[codex_subscription codex_responses gpt-6.2-astra gpt-6.2-sol].freeze,
    ].freeze

    # GenerateContent accepts the signed history of these four models across
    # the family. An unreviewed Gemini version retains exact-model binding.
    GEMINI_4 = %w[gemini-4-argon gemini-4-carbon gemini-4-hydrogen gemini-4-neon].freeze

    class << self
      def call(trace:, target:)
        new(trace, target).call
      rescue StandardError
        # I1, kept from the predecessor: a malformed trace never breaks a
        # request — it just doesn't ride.
        Decision.drop("trace_error")
      end

      # A Run extends the preceding sealed request. Keep its producer's
      # native item in that prefix so a later switch back can read it.
      # Build projects the sealed item for each recipient at dispatch.
      def for_sealed_round(trace:, target:)
        return call(trace: trace, target: target) if target.capability.none?

        if trace.origin_provider_id != target.provider_id || trace.origin_model_id != target.model_id
          producer = target.with(provider_id: trace.origin_provider_id, model_id: trace.origin_model_id,
            reasoning_enabled: true, capability: Nexus::ReasoningReplayCapability.new(format: trace.origin_format_variant))
          native = call(trace: trace, target: producer)
          return native if native.replayed?
        end
        # Some providers return only a display summary, with no native
        # item suitable for replay. Keep the normal portable fallback.
        call(trace: trace, target: target)
      end

      # The same origin rule applies when native material is already inside a
      # sealed prefix, rather than being replayed from a round's trace now.
      def origin_miss(origin:, provider_id:, model_id:, reasoning_enabled:, format:)
        return "origin_provider_mismatch" unless origin["provider_id"] == provider_id
        return "reasoning_disabled" if reasoning_enabled == false
        return if origin["model_id"] == model_id || CROSS_MODEL_FORMATS.include?(format)
        if format == "responses_reasoning" &&
            RESPONSES_NATIVE_SWITCHES.include?([provider_id, origin["api_format"], origin["model_id"], model_id])
          return
        end

        "cross_model_mismatch"
      end

      def gemini_signatures?(origin_model, target_model)
        origin_model == target_model || (GEMINI_4.include?(origin_model) && GEMINI_4.include?(target_model))
      end
    end

    def initialize(trace, target)
      @trace = trace
      @target = target
    end

    def call
      decision = case @target.capability.format
      when "none" then Decision.drop("replay_disabled")
      when "anthropic_thinking" then anthropic
      when "responses_reasoning" then responses
      when "gemini_thought" then gemini
      when "chat_reasoning" then chat
      when "responses_reasoning_text" then responses_text
      else raise ArgumentError, "unknown replay format #{@target.capability.format}"
      end
      switched = @trace.origin_provider_id != @target.provider_id || @trace.origin_model_id != @target.model_id
      if decision.kind == :drop && switched
        summaries = PortableSummary.from_trace(@trace)
        decision = decision.with(kind: :summary, payloads: summaries) if summaries.any?
      end
      return decision unless gemini_signatures?

      decision.with(call_payloads: tool_call_payloads,
        message_payloads: @trace.signed_messages.to_h { |item| [item.fetch("ordinal"), item.fetch("provider_payload").fetch("parts")] })
    end

    private

      # A function call can carry native state even without a display summary.
      def tool_call_payloads
        @trace.signed_calls
          .to_h { |item| [item["item_id"].to_s, item["provider_payload"]] }.compact.except("")
      end

      def anthropic
        miss = native_miss("anthropic_thinking")
        return Decision.drop(miss) if miss

        blocks = @trace.reasoning_items.filter_map do |item|
          block = anthropic_block(item)
          [item["ordinal"], block] if block
        end
        return Decision.drop("missing_signature") if blocks.empty?

        ordered_parts(blocks)
      end

      # Replay exactly what came back: the verbatim block wins (adaptive
      # thinking returns signature-only blocks synthesis cannot rebuild).
      def anthropic_block(item)
        payload = Hash.try_convert(item["provider_payload"])
        if payload
          case payload["type"].to_s
          when "thinking"
            payload if payload["signature"].to_s.present? &&
              item["signature_kind"].to_s == "anthropic_signature"
          when "redacted_thinking"
            payload if payload["data"].to_s.present?
          else nil
          end
        elsif item["redacted"] == true && item["encrypted_content"].present?
          { "type" => "redacted_thinking", "data" => item["encrypted_content"].to_s }
        elsif signed?(item, "anthropic_signature")
          { "type" => "thinking", "thinking" => item["text"].to_s,
            "signature" => item["signature"].to_s }
        end
      end

      # One native item per reasoning item that carries its blob, in trace
      # order, each with its OWN summary parts: a round that thought between
      # its calls replays every thought, never the first alone. An item
      # without a blob is display material (its summary already rides the
      # `reasoning` body) and is skipped.
      def responses
        miss = native_miss("responses_reasoning")
        return Decision.drop(miss) if miss

        placed = @trace.reasoning_items.filter_map do |item|
          next if item["encrypted_content"].blank?

          [item.fetch("ordinal"), native_reasoning_item(item)]
        end
        return Decision.drop("missing_encrypted_content") if placed.empty?

        Decision.native_items(placed)
      end

      # The wire's summary parts verbatim, `[]` when it sent none.
      def native_reasoning_item(item)
        { "type" => "reasoning", "encrypted_content" => item["encrypted_content"],
          "summary" => Array(item["summary"]) }
      end

      def gemini_signatures?
        native_miss("gemini_thought").nil? &&
          self.class.gemini_signatures?(@trace.origin_model_id, @target.model_id)
      end

      # A signature belongs to its original Part, including an empty signed
      # Part. Older envelopes may only carry the normalized summary text.
      def gemini
        miss = native_miss("gemini_thought")
        return Decision.drop(miss) if miss

        signed = gemini_signatures?
        parts = @trace.reasoning_items.flat_map do |item|
          next [] if item["redacted"]

          gemini_thought_parts(item).filter_map do |part|
            text = part["text"].to_s
            signature = (part["thoughtSignature"] || part["signature"]) if signed
            next if text.empty? && signature.blank?

            [item["ordinal"], { "type" => "thought", "text" => text, "thoughtSignature" => signature }.compact]
          end
        end
        return Decision.drop("missing_native_text") if parts.empty?

        ordered_parts(parts)
      end

      # If every thought precedes the text and calls, one host message
      # carries them. A later thought must stay beside the block it preceded.
      def ordered_parts(parts)
        decision = Decision.native_parts(parts.map(&:last))
        first_marker = @trace.markers.first
        if first_marker && parts.any? { |ordinal, _| ordinal > first_marker.fetch("ordinal") }
          decision = decision.with(kind: :placed_parts, ordinals: parts.map(&:first))
        end
        decision
      end

      # Earlier streams kept the whole summary in text but only the final
      # delta in provider_payload. Keep a signature on its exact original Part.
      def gemini_thought_parts(item)
        native = item["provider_payload"]
        return [item] unless native
        return native.fetch("parts") if native.key?("parts")

        full = item["text"]
        tail = native["text"].to_s
        return [native] if full.nil? || full == tail
        return [{ "text" => full }] unless native["thoughtSignature"].present? && full.end_with?(tail)

        [{ "text" => full.delete_suffix(tail) }, native]
      end

      # The chat assistant message's own field: the broker's detail blocks
      # verbatim and in order when it sent them — they may be encrypted or
      # signed, and the sequence must match what the model produced — else
      # the reasoning text. One payload, which Build lifts onto the message.
      def chat
        miss = native_miss("chat_reasoning")
        return Decision.drop(miss) if miss

        blocks = @trace.reasoning_items.filter_map { |item| Hash.try_convert(item["provider_payload"]) }
        return Decision.native_parts([{ "type" => "reasoning_details", "blocks" => blocks }]) if blocks.any?

        text = joined_text
        return Decision.drop("missing_native_text") if text.nil?

        Decision.native_parts([{ "type" => "reasoning_content", "text" => text }])
      end

      # DeepSeek's Responses route: one plain-text reasoning item per thought,
      # at the place it was thought (the route merges each into the
      # adjacent assistant message; it takes no summary and no blob).
      def responses_text
        miss = native_miss("responses_reasoning_text")
        return Decision.drop(miss) if miss

        placed = @trace.reasoning_items.filter_map do |item|
          text = item["text"].to_s
          next if text.empty?

          [item.fetch("ordinal"),
           { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => text }] }]
        end
        return Decision.drop("missing_native_text") if placed.empty?

        Decision.native_items(placed)
      end

      def native_miss(format_variant)
        return "capability_format_mismatch" unless
          @target.capability.format == format_variant
        return "origin_format_mismatch" unless
          @trace.origin_format_variant.to_s == format_variant
        # Providers reject native reasoning shapes when reasoning is off.
        self.class.origin_miss(origin: @trace.native_origin, provider_id: @target.provider_id,
          model_id: @target.model_id, reasoning_enabled: @target.reasoning_enabled, format: format_variant)
      end

      def signed?(item, kind)
        item["text"].to_s.present? &&
          item["signature"].to_s.present? &&
          item["signature_kind"].to_s == kind
      end

      def joined_text
        @trace.reasoning_items
          .reject { |item| item["redacted"] == true }
          .filter_map { |item| item["text"].presence }
          .join("\n\n")
          .presence
      end
  end
end
