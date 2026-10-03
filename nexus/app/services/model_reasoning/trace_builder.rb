module ModelReasoning
  # The capture half of cross-model reasoning: one provenance envelope
  # frozen at the only moment it exists, since it cannot be backfilled. A
  # replay sidecar, never presented. It also carries the provider's verdict
  # on the history it was handed, which exists only on that same answer.
  # Every answer whose output items hold a message or a call writes one, even
  # with nothing thought: its markers are the round's order and its
  # messages' labels, which every later rendering of the round reads,
  # replaying reasoning or not.
  class TraceBuilder
    FORMAT = "nexus.reasoning_trace.v1"
    TRACE_VERSION = 2

    # MARKERS are the answer's own output items in the walk — each message
    # and each call at its place — so a replay can put every reasoning item
    # before the item it produced. They are structure, never reasoning: no
    # replay rung and no fence reads them.
    ASSISTANT_MESSAGE = "assistant_message"
    TOOL_CALL = "tool_call"
    MARKER_KINDS = [ASSISTANT_MESSAGE, TOOL_CALL].freeze

    # Keyed by API format, which names the wire grammar (provider ids
    # differ per deployment); unknown formats degrade safely.
    ORIGIN_FORMAT_VARIANTS = {
      "anthropic_messages" => "anthropic_thinking",
      "openai_responses" => "responses_reasoning",
      "codex_responses" => "responses_reasoning",
      "xai_responses" => "responses_reasoning",
      "gemini_generate_content" => "gemini_thought",
      "deepseek_responses" => "responses_reasoning_text",
      "openai_compatible" => "chatcompletions_reasoning_content",
      "openrouter_chat" => "chat_reasoning",
    }.freeze

    # Signatures are not interchangeable across families: replay re-emits
    # one only to its origin family.
    SIGNATURE_KINDS = {
      "anthropic_messages" => "anthropic_signature",
      "gemini_generate_content" => "gemini_thought_signature",
    }.freeze

    class << self
      # `origin` stamps provenance at the execution boundary: model_id is
      # the lowered wire id, which a catalog ref cannot reconstruct later.
      # `input_transformations` is the provider's list of what it dropped or
      # rewrote in the replayed history, verbatim: `[]` says it replayed
      # intact and is a fact worth an envelope on its own; nil is a provider
      # that reports nothing.
      def call(result:, origin:, normalized_tool_calls:, input_transformations: nil)
        new(result, origin, normalized_tool_calls, input_transformations).call
      end
    end

    def initialize(result, origin, normalized_tool_calls, input_transformations)
      @result = result
      @origin = origin
      @calls_by_ordinal = normalized_tool_calls.index_by { |call| call.fetch("ordinal") }
      @input_transformations = input_transformations
    end

    def call
      items = collected_items
      return nil if items.empty? && @input_transformations.nil?

      {
        "type" => "reasoning_trace",
        "format" => FORMAT,
        "trace_version" => TRACE_VERSION,
        "origin_provider_id" => @origin[:provider_id].to_s.presence,
        "origin_model_id" => @origin[:model_id].to_s.presence,
        "origin_api_format" => api_format.presence,
        "origin_format_variant" => ORIGIN_FORMAT_VARIANTS.fetch(api_format, "none"),
        "origin_invocation_id" => @origin[:invocation_id].to_s.presence,
        "items" => items.each_with_index.map do |item, ordinal|
          item.merge("ordinal" => ordinal)
        end,
        "input_transformations" => @input_transformations,
      }.compact
    end

    private

      def api_format = @origin[:api_format].to_s

      def collected_items
        items = output_item_traces
        message = Hash.try_convert(@result.assistant_message) || {}
        details = detail_traces(message["reasoning_details"])
        # OpenRouter carries the same chain twice; the structured list is
        # the capture and the plain string is skipped, never both.
        items += message_text_traces(message) unless details.any? { |d| d["text"].present? }
        items += details
        # Token accounting rides ALONGSIDE material (the predecessor's
        # rule): the budget half prices native blobs with it, and a blob
        # item carries no count of its own.
        accounting = token_accounting_item
        if accounting && items.none? { |item| item["reasoning_tokens"].to_i.positive? }
          items << accounting
        end
        items.map { |item| stamp_provenance(item) }
      end

      # The output-items walk, ORDER-PRESERVING: position relative to tool
      # calls is load-bearing for interleaved replay, so ordinals follow
      # encounter order and every message and call holds its place.
      def output_item_traces
        call_ordinal = -1
        items = Array(@result.output_items).filter_map { |raw| Hash.try_convert(raw) }
        split = items.count { |item| item["type"].to_s == "message" } >= 2
        items.filter_map do |item|
          case item["type"].to_s
          when "reasoning"
            reasoning_item(item)
          when "redacted_thinking"
            # Anthropic's opaque block: the blob is the only replayable
            # signal, redacted by construction, re-emitted verbatim only.
            data = item["data"].to_s.presence
            if data
              { "kind" => "reasoning_encrypted", "encrypted_content" => data,
                "redacted" => true,
                "provider_payload" => Hash.try_convert(item["provider_payload"]) }.compact
            end
          when "message"
            message_marker(item, split)
          when "function_call", "tool_call"
            call_ordinal += 1
            tool_call_marker(item, @calls_by_ordinal[call_ordinal])
          else nil
          end
        end
      end

      def reasoning_item(item)
        traced = {
          "kind" => "reasoning_text",
          "text" => item_text(item),
          "summary_text" => summary_text(item),
          # The wire's summary PARTS, verbatim: the native replay sends them
          # back as they came, while `summary_text` is their joined display.
          "summary" => Array.try_convert(item["summary"])&.filter_map { |part| Hash.try_convert(part) },
          "signature" => item["signature"].to_s.presence,
          "encrypted_content" => item["encrypted_content"].to_s.presence,
          "item_id" => item["id"].to_s.presence,
          # The wire's own block, verbatim — the continuation contract is
          # replay-exactly-what-came-back, and Claude 5's signature-only
          # thinking (empty text) made synthesis from fields insufficient.
          "provider_payload" => Hash.try_convert(item["provider_payload"]),
        }.compact
        content?(traced) ? traced : nil
      end

      # The answer's message at its place, with the wire's `phase` when it
      # sent one. A single message's words are the body's, so they are stored
      # only when the answer is split across two or more messages.
      def message_marker(item, split)
        { "kind" => ASSISTANT_MESSAGE,
          "phase" => item["phase"].to_s.presence,
          "text" => (joined_parts(item["content"], %w[text]) if split) }.compact
      end

      # One marker per call the normalizer kept, keyed by its pairing id —
      # the normalizer owns that identity, including missing or repeated
      # provider ids, and its ordinal counts calls independently of trace
      # items. A signature the provider bound to the call rides on it.
      def tool_call_marker(item, call)
        return nil if call.nil?

        payload = Hash.try_convert(item["provider_payload"]) || {}
        signature = payload["thoughtSignature"].to_s.presence
        { "kind" => TOOL_CALL, "item_id" => call.fetch("id"), "signature" => signature,
          "provider_payload" => (payload if signature) }.compact
      end

      # Both spellings: streamed turns normalize onto `reasoning_content`,
      # a unary OpenRouter body keeps `reasoning`.
      def message_text_traces(message)
        text = message["reasoning_content"].to_s.presence ||
          message["reasoning"].to_s.presence
        return [] if text.nil?

        [{ "kind" => "reasoning_text", "text" => text }]
      end

      # OpenRouter's structured detail list (its echo-back contract): each
      # detail keeps its id, and its block VERBATIM as `provider_payload` —
      # the broker takes the sequence back only as the model produced it,
      # and an upstream's block may be encrypted or signed.
      def detail_traces(details)
        coalesced_details(details).filter_map do |detail|
          type = detail["type"].to_s
          traced =
            if type.include?("summary")
              { "kind" => "reasoning_summary",
                "summary_text" => first_present(detail, %w[summary text content]) }
            elsif type.include?("encrypted")
              { "kind" => "reasoning_encrypted",
                "encrypted_content" => first_present(detail, %w[data encrypted_content]) }
            else
              { "kind" => type.presence || "reasoning_detail",
                "text" => detail["text"].to_s.presence,
                "summary_text" => detail["summary"].to_s.presence,
                "encrypted_content" => first_present(detail, %w[data encrypted_content]) }
            end
          traced = traced.merge("item_id" => detail["id"].to_s.presence, "provider_payload" => detail).compact
          content?(traced) ? traced : nil
        end
      end

      # A CHUNK BOUNDARY IS NOT AN ITEM BOUNDARY. The openrouter lane
      # collects one detail per SSE chunk (the gem's observation is the
      # echo-back capture and rides the wire unmodified), so adjacent
      # deltas of one block — the same type, id and index — are ONE detail
      # whose text is their concatenation; a later chunk's other fields
      # (a signature on the last delta) win. Kept apart, the fenced replay
      # read "The\n\n test suite finished\n\n: 20 runs" back to the model.
      def coalesced_details(details)
        Array(details).filter_map { |raw| Hash.try_convert(raw) }
          .each_with_object([]) do |detail, blocks|
            previous = blocks.last
            if previous && same_block?(previous, detail)
              blocks[-1] = previous.merge(detail.compact).merge(
                "text" => joined_delta(previous["text"], detail["text"]),
                "summary" => joined_delta(previous["summary"], detail["summary"])
              ).compact
            else
              blocks << detail
            end
          end
      end

      def same_block?(previous, detail)
        type = detail["type"].to_s
        return false if type.include?("encrypted")

        previous["type"].to_s == type && previous["id"].to_s == detail["id"].to_s &&
          previous["index"] == detail["index"]
      end

      def joined_delta(head, tail)
        [head, tail].compact.map(&:to_s).join.presence
      end

      # Reasoning that happened but left no material still leaves its
      # receipt: token accounting is a trace fact (the budget half of
      # replay prices native blobs with it).
      def token_accounting_item
        tokens = reasoning_tokens
        return nil if tokens.nil?

        { "kind" => "token_accounting", "reasoning_tokens" => tokens }
      end

      # Read where the receipt reads it (UsageRecords::Tokens), every
      # spelling included — Anthropic's `thinking_tokens` among them, whose
      # signed block's text is only a summary of what the server bills.
      def reasoning_tokens
        tokens = UsageRecords::Tokens.read(@result.usage, adapter_profile: api_format).fetch(:reasoning_tokens)
        tokens if tokens.to_i.positive?
      end

      # Per-item provenance: the signature binds to its origin family, and
      # an anthropic encrypted-without-text item is redacted material even
      # when it arrived unlabeled.
      def stamp_provenance(item)
        stamped = item
        if item["signature"]
          stamped = stamped.merge(
            "signature_kind" => SIGNATURE_KINDS.fetch(api_format, "none")
          )
        end
        if api_format == "anthropic_messages" && item["encrypted_content"] &&
            item["text"].nil? && item["summary_text"].nil?
          stamped = stamped.merge("redacted" => true)
        end
        stamped
      end

      def item_text(item)
        text = item["text"].to_s.presence
        return text if text

        joined_parts(item["content"], %w[text content])
      end

      def summary_text(item)
        text = item["summary_text"].to_s.presence
        return text if text

        joined_parts(item["summary"], %w[text summary_text content])
      end

      def joined_parts(parts, keys)
        Array(parts).filter_map do |raw|
          part = Hash.try_convert(raw)
          next if part.nil?

          first_present(part, keys)
        end.join.presence
      end

      def first_present(hash, keys)
        keys.filter_map { |key| hash[key].to_s.presence }.first
      end

      # An item with encrypted content and no text is CONTENT, never
      # dropped — the empty-text-but-encrypted rule.
      def content?(item)
        item["text"].present? || item["summary_text"].present? ||
          item["signature"].present? || item["encrypted_content"].present? ||
          item["reasoning_tokens"].to_i.positive?
      end
  end
end
