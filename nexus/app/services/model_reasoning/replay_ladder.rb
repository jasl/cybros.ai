module ModelReasoning
  # The per-turn replay ladder: the native shape where the target can read
  # the trace's origin, else nothing — a trace another provider, wire or
  # (on the formats bound to their model) model produced contributes no
  # bytes, the way the vendors themselves drop reasoning a model cannot
  # read. Every miss names its gate. Never raises.
  class ReplayLadder
    Target = Data.define(:provider_id, :model_id, :reasoning_enabled, :capability)

    # kind: :native_parts (in-message blocks, or the chat message's field) |
    # :native_item (role-less items, one per replayed reasoning item) |
    # :drop. `ordinals` names the trace item each native item came from,
    # parallel to `payloads` (`[]` for the other kinds), so a renderer
    # places each where it was thought without re-deciding which items
    # replay. Call payloads have their own rung: a signature can ride
    # without any standalone reasoning, even when kind is :drop.
    Decision = Data.define(:kind, :payloads, :ordinals, :reason, :call_payloads) do
      class << self
        def native_parts(payloads) = new(kind: :native_parts, payloads: payloads, reason: nil)

        # `placed` is `[[ordinal, payload], ...]` in trace order.
        def native_items(placed)
          new(kind: :native_item, payloads: placed.map(&:last), ordinals: placed.map(&:first), reason: nil)
        end

        def drop(reason) = new(kind: :drop, payloads: [], reason: reason)
      end

      def initialize(ordinals: [], call_payloads: {}, **) = super

      def replayed? = kind != :drop || call_payloads.any?
    end

    # The formats a provider carries across its own models: Anthropic
    # accepts every block back and drops, silently and unbilled, what the
    # current model cannot read; Gemini accepts unsigned thought parts
    # across its models. Every other format is bound to the model that
    # produced it — an encrypted item, and a chat reasoning sequence, which
    # must match what that model generated.
    CROSS_MODEL_FORMATS = %w[anthropic_thinking gemini_thought].freeze

    class << self
      def call(trace:, target:)
        new(trace, target).call
      rescue StandardError
        # I1, kept from the predecessor: a malformed trace never breaks a
        # request — it just doesn't ride.
        Decision.drop("trace_error")
      end

      # The same origin rule applies when native material is already inside a
      # sealed prefix, rather than being replayed from a round's trace now.
      def origin_miss(origin:, provider_id:, model_id:, reasoning_enabled:, require_same_model: true)
        return "origin_provider_mismatch" unless origin["provider_id"] == provider_id
        return "reasoning_disabled" if reasoning_enabled == false
        return "cross_model_mismatch" if require_same_model && origin["model_id"] != model_id

        nil
      end

      def same_model?(format) = !CROSS_MODEL_FORMATS.include?(format)
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
      decision.with(call_payloads: tool_call_payloads)
    end

    private

      # Signed function calls have their own native rung even when no
      # readable thought exists; unlike Gemini text they require the exact model.
      def tool_call_payloads
        return {} if native_miss("gemini_thought", require_same_model: true)

        @trace.signed_calls
          .to_h { |item| [item["item_id"].to_s, item["provider_payload"]] }.compact.except("")
      end

      def anthropic
        miss = native_miss("anthropic_thinking")
        return Decision.drop(miss) if miss

        blocks = @trace.reasoning_items.filter_map { |item| anthropic_block(item) }
        return Decision.drop("missing_signature") if blocks.empty?

        Decision.native_parts(blocks)
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

      # Gemini's unsigned thought parts are accepted across its models
      # (probe-backed): the thought texts joined, redacted material never.
      def gemini
        miss = native_miss("gemini_thought")
        return Decision.drop(miss) if miss

        text = joined_text
        return Decision.drop("missing_native_text") if text.nil?

        Decision.native_parts([{ "type" => "thought", "text" => text }])
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

      def native_miss(format_variant, require_same_model: self.class.same_model?(format_variant))
        return "capability_format_mismatch" unless
          @target.capability.format == format_variant
        return "origin_format_mismatch" unless
          @trace.origin_format_variant.to_s == format_variant
        # Providers reject native reasoning shapes when reasoning is off.
        self.class.origin_miss(origin: @trace.native_origin, provider_id: @target.provider_id,
          model_id: @target.model_id, reasoning_enabled: @target.reasoning_enabled,
          require_same_model: require_same_model)
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
