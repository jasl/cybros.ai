require_relative "base"

module SimpleInference
  module Protocols
    class AnthropicMessages < Base
      require_relative "anthropic_messages/request_body"

      include RequestBody

      # WHAT THIS WIRE ACCEPTS — an audited protocol fact, so the protocol
      # class owns it. A LEADING `system` run rides the top-level parameter;
      # a mid-conversation one is a wire message only under the row's
      # `mid_conversation_system` fact (coerce_messages); `developer` has no
      # twin on the wire and lowers to `user` in place (normalize_role), so
      # it is ACCEPTED — the consumer's admission reads this constant, and a
      # constant narrower than normalize_role parked every developer-led
      # conversation before the wire that would have carried it.
      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze

      # The closed wire vocabulary for output_config.effort. "none" is the
      # kernel's disable spelling and lowers to thinking {type: "disabled"};
      # everything else ("minimal", unknown values) is a loud local rejection
      # — this protocol lowers efforts faithfully and NEVER clamps. Model-name
      # dispatch is dead: no claude-* regex may select a lowering branch.
      # This is the WIRE GATE — the anthropic registry rows'
      # `reasoning_options` efforts are the other fact with the other job
      # (the reviewed per-lane catalog subset offered at selection), which
      # may narrow this set but never exceed it (pinned by
      # test_reasoning_wire_gates).
      REASONING_EFFORT_VOCABULARY = [
        "low".freeze,
        "medium".freeze,
        "high".freeze,
        "xhigh".freeze,
        "max".freeze,
      ].freeze

      # Anthropic documents this HTTP-200 SSE error as the streaming
      # equivalent of HTTP 529. It therefore belongs to the retryable
      # interruption family; other stream error events remain ordinary
      # terminal provider errors.
      class StreamOverloadedError < SimpleInference::ProviderStreamInterruptedError
        def overloaded? = true
      end

      # Register minimum for manual thinking budgets (budget_tokens).
      MANUAL_THINKING_BUDGET_MINIMUM = 1024

      # Deterministic wire constants (labeled): the ONE Messages endpoint
      # every request posts to, and the pinned wire-version marker. The
      # version marker is NON-credential protocol vocabulary — it rides
      # protocol_headers — while x-api-key stays Config-owned and merges only
      # at execution.
      #
      # Both are registry-declared construction facts (post-Stage-4 re-audit,
      # fix 2): the anthropic rows' wire_options declare
      # messages_path/anthropic_version and ApiFormat.protocol_for
      # feeds them; these constants keep the same values for a lane built
      # without a profile.
      MESSAGES_PATH = "/v1/messages".freeze
      ANTHROPIC_VERSION = "2023-06-01".freeze

      # The betas a BODY implies (alignment 2026-09-16, F10/F13): a beta
      # header rides exactly when its field does, so a row never declares
      # one of these — `betas:` is for the rest (server-side fallback,
      # clear_at, ...). thinking-binding-controls carries
      # thinking.block_binding; mid-conversation-output-config carries an
      # in-place system message's output_config (the migration guide's
      # effort-change recipe).
      BETA_THINKING_BINDING_CONTROLS = "thinking-binding-controls-2026-08-01".freeze
      BETA_MID_CONVERSATION_OUTPUT_CONFIG = "mid-conversation-output-config-2026-07-01".freeze

      # The wire's vocabulary for thinking.block_binding.prefix_mismatch_behavior
      # (the guide: `error` is the server default, `drop_block` drops the
      # thinking blocks whose bound prefix — system, tools, earlier turns —
      # no longer matches instead of answering 400 "Invalid signature").
      THINKING_BINDING_BEHAVIORS = %w[error drop_block].freeze

      # What the wire refuses in a tool id (`tool_use.id` must match
      # ^[a-zA-Z0-9_-]+$ — a 400 otherwise). Another provider's id replayed
      # after a model switch (kimi's `read:0`) is scrubbed to `_`, as
      # opencode does (anthropic-messages.ts scrubToolCallID); the scrub is
      # deterministic, so a tool_use and its tool_result still pair, and the
      # kernel's stored ids never change.
      TOOL_ID_REFUSED = /[^a-zA-Z0-9_-]/

      # Three more registry-declared construction facts beside the path and
      # the version marker (alignment 2026-09-16):
      # - betas: extra `anthropic-beta` tokens the row wants on every request;
      # - thinking_binding: the fable-5-1 and opus-5-5 rows' `drop_block` —
      #   SCOPED BY MODEL ID on the row, never by lane (older deployments may
      #   reject the field; opencode gates it at claude >= 5.1 except
      #   mythos-5.1);
      # - mid_conversation_system: the row states that `role: system` is a
      #   wire message inside messages[] (GA on fable-5-1 / fable-5 /
      #   opus-5-5 / opus-5 / opus-4-8, not on sonnet-5); without it a
      #   non-leading system entry lowers in place to user text.
      def initialize(messages_path: nil, anthropic_version: nil, betas: nil, thinking_binding: nil,
                     mid_conversation_system: nil, **connection)
        super(**connection)
        @messages_path = normalized_messages_path(messages_path)
        @anthropic_version = validated_anthropic_version(anthropic_version)
        @betas = validated_betas(betas)
        @thinking_binding = validated_thinking_binding(thinking_binding)
        @mid_conversation_system = mid_conversation_system == true
      end

      # The responses-family options this protocol PROCESSES by name (thinking
      # mapping, tool conversion, message coalescing); Anthropic-specific wire
      # fields (metadata, stop_sequences, ...) ride extra_body.
      # :n and :response_format stay DECLARED so the kernel's splitter routes
      # them here, but they are inventoried LOCAL REJECTIONS, never silent
      # drops: :n always raises (/v1/messages has no multi-candidate concept
      # and 400s on unknown top-level fields), and :response_format raises for
      # any type other than json_schema — {type: "json_schema"} maps onto the
      # GA structured-output field output_config.format (no beta header);
      # json_object has no Anthropic equivalent.
      def self.request_option_keys
        %i[
          max_output_tokens temperature top_p top_k instructions
          tools tool_choice parallel_tool_calls
          reasoning_enabled reasoning_effort thinking output_config
          n response_format
        ].freeze
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(build_request_body(model: model, input: input, options: declared), extra_body)

        compile_json_request(path: @messages_path, body: body, stream: false) do |connection_config, compiled|
          anthropic_result_from_response(compiled_response(compiled, config: connection_config))
        end
      end

      def compile_stream(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(
          build_request_body(model: model, input: input, options: declared).merge(stream: true),
          extra_body
        )

        compile_json_request(path: @messages_path, body: body, stream: true) do |connection_config, compiled|
          stream_from_compiled(connection_config, compiled)
        end
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def stream_from_compiled(connection_config, compiled)
        SimpleInference::Responses::Stream.new do |&emit|
          result =
            stream_result(connection_config: connection_config, compiled: compiled) do |event, state|
              case event.dig("delta", "type").to_s
              when "text_delta"
                emit.call(
                  SimpleInference::Responses::Events::TextDelta.new(
                    delta: event.dig("delta", "text")
                  )
                )
              when "thinking_delta"
                block = state.fetch("content", []).fetch(event.fetch("index"), {})
                emit.call(
                  SimpleInference::Responses::Events::ReasoningDelta.new(
                    delta: event.dig("delta", "thinking"),
                    kind: "thinking",
                    item_id: block["id"]
                  )
                )
              when "input_json_delta"
                block = state.fetch("content", []).fetch(event.fetch("index"), {})
                emit.call(
                  SimpleInference::Responses::Events::ToolCallDelta.new(
                    item_id: block["id"],
                    call_id: block["id"],
                    name: block["name"],
                    delta: event.dig("delta", "partial_json")
                  )
                )
              else
                nil
              end

              if event["type"].to_s == "content_block_stop"
                block = state.fetch("content", []).fetch(event.fetch("index"), {})
                if block["type"].to_s == "tool_use"
                  emit.call(
                    SimpleInference::Responses::Events::ToolCallDone.new(
                      item_id: block["id"],
                      call_id: block["id"],
                      name: block["name"],
                      arguments: tool_use_arguments(block)
                    )
                  )
                end
              end
            end

          emit.call(SimpleInference::Responses::Events::Completed.new(result: result))
          result
        end
      end

      private

      def anthropic_result_from_response(response)
        anthropic_result_from_body(response.body || {}, provider_response: response)
      end

      # A streamed message has no unary provider response to carry — its
      # exchange IS the event sequence — so the slot is honestly nil there.
      #
      # `finish_detail` is the typed `stop_details.type` when the wire sends
      # one (a classifier refusal is HTTP 200 + stop_reason "refusal" +
      # stop_details {type, category, explanation}), else the bare
      # stop_reason. A refusal's category and explanation ride the Result's
      # `refusal`, both nullable as the wire sends them; on a stream the
      # text that went out before the classifier stopped it stays on the
      # Result beside the refusal. The raw stop_details hash and the
      # `input_transformations` list (F10c: what the server dropped or
      # rewrote — prefix_binding_mismatch / model_binding_mismatch, an empty
      # array meaning the history replayed intact) stay on the provider
      # response the Result carries; the consumer reads them from there.
      def anthropic_result_from_body(body, provider_response: nil)
        content = Array(body["content"])
        output_items = normalize_output_items(content)
        stop_details = body["stop_details"] || {}
        finish_detail = stop_details["type"] || body["stop_reason"]

        SimpleInference::Responses::Result.new(
          id: body["id"],
          output_text: content.filter_map { |item| item["text"] }.join,
          output_items: output_items,
          tool_calls: SimpleInference::Responses::Result.tool_calls_from_output_items(output_items),
          usage: normalize_usage(body["usage"]),
          finish_reason: body["stop_reason"],
          finish_detail: finish_detail,
          refusal: SimpleInference::Responses::Refusal.for_finish(
            FinishQuality::MESSAGES, finish_detail,
            category: stop_details["category"], explanation: stop_details["explanation"]
          ),
          provider_response: provider_response,
          provider_format: "responses"
        )
      end

      def stream_result(connection_config:, compiled:)
        message = nil
        message_stop_seen = false
        events_seen = 0
        last_event_type = nil

        response =
          compiled_stream_response(compiled, config: connection_config) do |_event_name, event|
            events_seen += 1
            last_event_type = event["type"].to_s
            raise_on_stream_error_event(event)
            message_stop_seen ||= event["type"].to_s == "message_stop"
            message = apply_stream_event(message, event)
            yield(event, message) if block_given?
          end

        # A Hash body means the server ignored Accept and answered with one
        # complete JSON Message — no SSE terminal exists to guard. Otherwise a
        # stream that ended without message_stop is an INTERRUPTION — the
        # SHARED cross-protocol typed error, never a normal Result.
        unless message_stop_seen || response.body
          raise SimpleInference::ProviderStreamInterruptedError.new(
            "anthropic stream ended without message_stop — interrupted stream, not a normal Result",
            events_seen: events_seen,
            last_event_type: last_event_type,
          )
        end

        body = response.body || message || {}
        response = response.with(body: body) if response.body.nil? && !body.empty?

        anthropic_result_from_response(response)
      end

      # The NON-credential half of the wire headers: the pinned wire-version
      # marker every Messages request carries (a registry-declared
      # construction fact) and the comma-joined `anthropic-beta` list — the
      # row's declared betas plus the ones the BODY implies (a beta rides
      # exactly when its field does). Stateless: derived from the finalized
      # string-keyed body, no per-request ivars.
      def protocol_headers(body)
        headers = { "anthropic-version" => @anthropic_version }
        betas = (@betas + implied_betas(body)).uniq
        betas.empty? ? headers : headers.merge("anthropic-beta" => betas.join(","))
      end

      def implied_betas(body)
        implied = []
        implied << BETA_THINKING_BINDING_CONTROLS if body.dig("thinking", "block_binding")
        if Array(body["messages"]).any? { |message| message["role"] == "system" && message.key?("output_config") }
          implied << BETA_MID_CONVERSATION_OUTPUT_CONFIG
        end
        implied
      end

      # The row's extra beta tokens: an Array of non-blank Strings, or nothing.
      def validated_betas(value)
        betas = Array(value).map(&:to_s)
        return betas.freeze if betas.none? { |beta| beta.strip.empty? }

        raise SimpleInference::ConfigurationError,
              "betas must be an Array of non-blank beta names (got #{value.inspect})"
      end

      def validated_thinking_binding(value)
        return nil if value.nil?
        return value.to_s if THINKING_BINDING_BEHAVIORS.include?(value.to_s)

        raise SimpleInference::ConfigurationError,
              "thinking_binding must be one of #{THINKING_BINDING_BEHAVIORS.join("|")} " \
              "(thinking.block_binding.prefix_mismatch_behavior; got #{value.inspect})"
      end

      # The registry-declared Messages endpoint; the frozen constant is the
      # direct-construction default.
      def normalized_messages_path(value)
        path = value.to_s.strip
        return MESSAGES_PATH if path.empty?

        path.start_with?("/") ? path : "/#{path}"
      end

      # The registry-declared wire-version marker; the frozen constant is
      # the direct-construction default.
      def validated_anthropic_version(value)
        return ANTHROPIC_VERSION if value.nil?
        return value.to_s unless value.to_s.strip.empty?

        raise SimpleInference::ConfigurationError,
              "anthropic_version must be a non-blank String (got #{value.inspect})"
      end

      def anthropic_headers(connection_config)
        headers = connection_config.headers.reject { |key, _value| key.to_s.casecmp("authorization").zero? }
        # No api_key means NO credential header — never an empty "x-api-key".
        connection_config.api_key.nil? ? headers : headers.merge("x-api-key" => connection_config.api_key)
      end

      def compiled_connection_headers(connection_config)
        anthropic_headers(connection_config)
      end

      # A mid-stream `event: error` (for example overloaded_error) may arrive
      # after HTTP 200 and VOIDS the message_stop terminal guarantee; evidence
      # after it is partial. It must surface loudly, never be swallowed by the
      # stream reducer's else-branch.
      def raise_on_stream_error_event(event)
        return unless event["type"].to_s == "error"

        error = event["error"] || {}
        details = [error["type"], error["message"]].reject { |value| value.to_s.empty? }

        message = "anthropic stream reported a mid-stream error event — " \
                  "the message_stop terminal guarantee is voided and evidence after it is partial"
        message = "#{message} (#{details.join(": ")})" if details.any?
        raise StreamOverloadedError, message if error["type"].to_s == "overloaded_error"

        raise SimpleInference::Error, message
      end

      def apply_stream_event(message, event)
        event = Internal::Keys.shallow_stringify(event)
        current = message

        case event["type"].to_s
        when "message_start"
          message = Internal::Keys.deep_stringify(event["message"])
          message["content"] = Array(message["content"]).map { |item| Internal::Keys.deep_stringify(item) }
          message
        when "content_block_start"
          current ||= { "content" => [] }
          current["content"] ||= []
          current["content"][event.fetch("index")] = Internal::Keys.deep_stringify(event["content_block"])
          current
        when "content_block_delta"
          current ||= { "content" => [] }
          current["content"] ||= []
          index = event.fetch("index")
          block = current["content"][index] ||= {}
          delta = Internal::Keys.shallow_stringify(event["delta"])

          case delta["type"].to_s
          when "text_delta"
            block["text"] = block["text"].to_s + delta["text"].to_s
          when "thinking_delta"
            block["thinking"] = block["thinking"].to_s + delta["thinking"].to_s
          when "signature_delta"
            block["signature"] = delta["signature"].to_s unless delta["signature"].nil?
          when "input_json_delta"
            block["_input_json"] = block["_input_json"].to_s + delta["partial_json"].to_s
          else
            nil
          end

          current
        when "content_block_stop"
          current ||= { "content" => [] }
          index = event.fetch("index")
          block = current["content"][index] ||= {}
          finalize_stream_block(block)
          current
        when "message_delta"
          current ||= { "content" => [] }
          delta = Internal::Keys.shallow_stringify(event["delta"])
          usage = Internal::Keys.shallow_stringify(event["usage"])
          current["stop_reason"] = delta["stop_reason"] unless delta["stop_reason"].nil?
          current["stop_sequence"] = delta["stop_sequence"] unless delta["stop_sequence"].nil?
          current["stop_details"] = Internal::Keys.deep_stringify(delta["stop_details"]) unless delta["stop_details"].nil?
          # message_start carries the message's own list; a delta appends.
          unless delta["input_transformations"].nil?
            current["input_transformations"] =
              Array(current["input_transformations"]) +
              Array(delta["input_transformations"]).map { |entry| Internal::Keys.deep_stringify(entry) }
          end
          current["usage"] = Internal::Keys.deep_stringify(current["usage"]).merge(usage)
          current
        else
          current || { "content" => [] }
        end
      end

      # A stream cut mid-call (max_tokens) leaves input JSON that never
      # closes; it stays on the block as the call's arguments so the caller
      # refuses the call as data the model reads — `{}` would run it with
      # no arguments (D4, 2026-09-05).
      def finalize_stream_block(block)
        return unless block["type"].to_s == "tool_use"

        partial_json = block["_input_json"].to_s
        return if partial_json.empty?

        block["input"] = JSON.parse(partial_json)
        block.delete("_input_json")
      rescue JSON::ParserError
        nil
      end

      def tool_use_arguments(block)
        # Empty deltas add no argument bytes; the start block's input still applies.
        partial_json = block["_input_json"].to_s
        partial_json.empty? ? JSON.generate(block["input"] || {}) : partial_json
      end

      def normalize_output_items(content)
        Array(content).filter_map do |item|
          normalized = Internal::Keys.shallow_stringify(item)

          case normalized["type"].to_s
          when "tool_use"
            {
              "type" => "function_call",
              "id" => normalized["id"],
              "call_id" => normalized["id"],
              "name" => normalized["name"],
              "arguments" => tool_use_arguments(normalized),
              "provider_payload" => normalized,
            }.compact
          when "text"
            {
              "type" => "message",
              "content" => [
                {
                  "type" => "output_text",
                  "text" => normalized["text"].to_s,
                },
              ],
            }
          when "thinking"
            {
              "type" => "reasoning",
              "text" => normalized["thinking"].to_s,
              "signature" => normalized["signature"],
              "provider_payload" => normalized,
            }.compact
          when "redacted_thinking"
            # Surfaced faithfully (not as a "reasoning" item) so the kernel
            # can replay the opaque block verbatim on the next turn.
            {
              "type" => "redacted_thinking",
              "data" => normalized["data"].to_s,
              "provider_payload" => normalized,
            }
          else
            nil
          end
        end
      end

      def normalize_usage(usage)
        usage.nil? ? nil : Internal::Keys.shallow_stringify(usage)
      end

      # Replay lowering: a call the kernel refused for unparseable
      # arguments still needs a legal tool_use block beside its error
      # result, so `{}` is the wire's only spelling here — the other
      # direction (tool_use_arguments) keeps the partial.
      # Arguments arrive as the wire's JSON text or an already-parsed Hash.
      def parse_arguments(value)
        case value
        when Hash then value
        when nil, "" then {}
        else JSON.parse(value.to_s)
        end
      rescue JSON::ParserError
        {}
      end

      def stringify_content(value)
        case value
        when String
          value
        when Hash, Array
          JSON.generate(value)
        else
          value.to_s
        end
      end
    end
  end
end
