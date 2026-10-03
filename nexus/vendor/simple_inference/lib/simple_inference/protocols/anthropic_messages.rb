require_relative "base"

module SimpleInference
  module Protocols
    class AnthropicMessages < Base
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
          reasoning_effort thinking output_config
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
        block["_input_json"] || JSON.generate(block["input"] || {})
      end

      def build_request_body(model:, input:, options:)
        reject_inventoried_options(options)

        system, messages = coerce_messages(input, options)
        reject_assistant_last(messages)

        body = {
          model: model,
          max_tokens: required_max_tokens(options[:max_output_tokens]),
          messages: messages,
        }

        # `system` is a String (cache off — byte-identical to before) or a
        # structured block array (the kernel marked a block with cache_control);
        # build_system already returns nil when empty.
        body[:system] = system unless system.nil?

        tools = normalize_tools(options[:tools])
        body[:tools] = tools if tools.any?
        tool_choice = build_tool_choice(
          tool_choice: options[:tool_choice],
          parallel_tool_calls: if options.key?(:parallel_tool_calls)
                                 options[:parallel_tool_calls]
                               end
        )
        body[:tool_choice] = tool_choice if tool_choice

        body[:temperature] = options[:temperature] if options.key?(:temperature)
        body[:top_p] = options[:top_p] if options.key?(:top_p)
        body[:top_k] = options[:top_k] if options.key?(:top_k)
        apply_thinking_options(body, options)

        body
      end

      # `max_tokens` is a REQUIRED Messages field and the caller's fact (the
      # row's max_output_tokens generation parameter, defaulting to the
      # model's output limit). Until 2026-09-16 a missing value fell back to
      # 1024 — a silent ceiling on every turn, cutting any tool call over
      # ~1k tokens. opencode's fallback is the model's output limit, else
      # 4096 (anthropic-messages.ts:521,571), never 1024; this protocol
      # invents no number at all: a row without the parameter fails loudly
      # here, mirroring the manual-thinking refusal below.
      def required_max_tokens(value)
        return value if value.is_a?(Integer) && value.positive?

        raise SimpleInference::ValidationError,
              "max_output_tokens is required on this wire (max_tokens is a required Messages field; " \
              "declare the row's max_output_tokens generation parameter — got #{value.inspect})"
      end

      # Inventoried local rejections replacing the former silent drops. Each
      # rejection is deterministic, happens pre-IO, and names its reason.
      def reject_inventoried_options(options)
        return unless options.key?(:n)

        raise SimpleInference::ValidationError,
              "anthropic_messages locally rejects n (result_count): /v1/messages has no " \
              "multi-candidate concept and rejects unknown top-level fields with a 400; " \
              "remove the option instead of expecting a silent drop"
      end

      # Register final-turn disposition: the lane rejects a last nonempty
      # assistant prefill; prior assistant history remains eligible. Rejected
      # pre-flight (zero outbound IO), never dropped/relabeled/padded.
      def reject_assistant_last(messages)
        return unless messages.last && messages.last[:role].to_s == "assistant"

        raise SimpleInference::ValidationError,
              "anthropic_messages rejects assistant-last input: the final nonempty turn must " \
              "not be an assistant prefill (prior assistant turns remain eligible)"
      end

      # Faithful lowering, no model dispatch: reasoning_effort "none" becomes
      # the explicit wire disable; an in-vocabulary effort rides adaptive mode
      # plus output_config.effort; a caller-supplied thinking Hash reaches the
      # wire verbatim (manual budgets are ONLY ever caller-chosen). Server-side
      # legality of a mode on a given model is the caller/profile's contract.
      def apply_thinking_options(body, options)
        effort = validated_reasoning_effort(options[:reasoning_effort])
        thinking = bind_thinking(anthropic_thinking_config(effort, options[:thinking]))
        body[:thinking] = thinking if thinking
        validate_manual_thinking(thinking, body)

        output_config = anthropic_output_config(options, effort: effort)
        body[:output_config] = output_config if output_config
      end

      # The row's `thinking_binding` fact lowers to
      # thinking.block_binding.prefix_mismatch_behavior on adaptive AND
      # manual enabled thinking (the two modes that produce signed blocks),
      # never on disabled; a caller's explicit block_binding wins, as
      # opencode's does (transform.ts:729). The beta follows the field
      # (protocol_headers).
      def bind_thinking(thinking)
        return thinking if @thinking_binding.nil? || thinking.nil?
        return thinking unless %w[adaptive enabled].include?(thinking[:type].to_s)
        return thinking if thinking.key?(:block_binding)

        thinking.merge(block_binding: { prefix_mismatch_behavior: @thinking_binding })
      end

      def validated_reasoning_effort(effort)
        return nil if effort.nil?

        value = effort.to_s
        return value if value == "none" || REASONING_EFFORT_VOCABULARY.include?(value)

        raise SimpleInference::ValidationError,
              "anthropic_messages accepts reasoning_effort none|#{REASONING_EFFORT_VOCABULARY.join("|")} " \
              "(got #{value.inspect}); efforts lower faithfully — this protocol never clamps"
      end

      def anthropic_thinking_config(effort, explicit_thinking)
        unless explicit_thinking.nil?
          thinking = Internal::Keys.shallow_symbolize(explicit_thinking)
          ensure_effort_thinking_consistency(effort, thinking)
          return thinking
        end

        return nil if effort.nil?

        # display: "summarized" is this lane's CAPTURE DEFAULT (the
        # reasoning-capture posture, like the responses family's
        # store:false + encrypted include): "omitted" — the wire's own
        # default on the Claude 5 family — returns signature-only blocks
        # with empty text, which replay same-model but leave nothing to
        # display or to carry across a model switch. Summaries bill the
        # same as omitted (display controls visibility only). A caller's
        # explicit :thinking hash overrides, as everywhere on this lane.
        effort == "none" ? { type: "disabled" } : { type: "adaptive", display: "summarized" }
      end

      # Effort rides output_config.effort in adaptive mode only; pairing it
      # with a manual/disabled thinking Hash is a contradiction the caller
      # must resolve — silently dropping either side would hide a decision.
      def ensure_effort_thinking_consistency(effort, thinking)
        return if effort.nil?

        type = thinking[:type].to_s
        return if effort == "none" ? type == "disabled" : type == "adaptive"

        raise SimpleInference::ValidationError,
              "reasoning_effort #{effort.inspect} conflicts with explicit thinking type #{type.inspect}: " \
              "effort rides output_config.effort in adaptive mode only (\"none\" pairs with type \"disabled\")"
      end

      # Manual mode is caller-chosen; the protocol validates the register's
      # hard bounds instead of silently repairing the request (the old code
      # bumped max_tokens to budget+1024 behind the caller's back).
      def validate_manual_thinking(thinking, body)
        return unless thinking && thinking[:type].to_s == "enabled"

        budget = thinking[:budget_tokens]
        unless budget.is_a?(Integer) && budget >= MANUAL_THINKING_BUDGET_MINIMUM
          raise SimpleInference::ValidationError,
                "thinking.budget_tokens must be an Integer >= #{MANUAL_THINKING_BUDGET_MINIMUM} " \
                "(got #{budget.inspect})"
        end

        max_tokens = body[:max_tokens].to_i
        return if max_tokens > budget

        raise SimpleInference::ValidationError,
              "max_tokens (#{max_tokens}) must exceed thinking.budget_tokens (#{budget}); " \
              "pass a larger max_output_tokens — the protocol no longer bumps it silently"
      end

      def anthropic_output_config(options, effort:)
        output_config = Internal::Keys.shallow_symbolize(options[:output_config])
        output_config[:effort] = effort if effort && effort != "none" && !output_config.key?(:effort)
        format = anthropic_output_format(options[:response_format])
        output_config[:format] = format if format && !output_config.key?(:format)

        output_config.empty? ? nil : output_config
      end

      # GA structured output: output_config.format only accepts the
      # json_schema variant (reference: json_output_format.rb). Any other
      # envelope type (json_object included) has no Anthropic equivalent and
      # is a loud inventoried rejection, never a silent drop.
      # The caller's response_format enters here once: an envelope Hash whose
      # json_schema variant carries a schema Hash (flat, or nested OpenAI-style
      # under json_schema:).
      def anthropic_output_format(response_format)
        return nil if response_format.nil?

        unless response_format.is_a?(Hash)
          raise SimpleInference::ValidationError, "response_format must be a Hash"
        end

        envelope = Internal::Keys.shallow_symbolize(response_format)
        type = envelope[:type].to_s
        unless type == "json_schema"
          raise SimpleInference::ValidationError,
                "anthropic_messages locally rejects response_format type #{type.inspect}: " \
                "output_config.format accepts only json_schema (no Anthropic equivalent exists)"
        end

        schema = envelope[:schema] || Internal::Keys.shallow_symbolize(envelope[:json_schema])[:schema]
        raise SimpleInference::ValidationError, "response_format json_schema requires a schema Hash" unless schema.is_a?(Hash)

        { type: "json_schema", schema: schema }
      end

      # The caller's input enters here once: a String, or an Array whose
      # entries are message Hashes or bare user strings.
      #
      # System entries split by POSITION (alignment 2026-09-16, F11): the
      # LEADING run (every system entry before the first wire message) is
      # hoisted into the top-level `system` field on every row; a NON-LEADING
      # one stays WHERE THE CALLER PLACED IT — hoisting it reordered history
      # ahead of the turns it followed, which breaks the cached prefix and
      # the thinking-block binding alike. In place it is a wire
      # `role: system` message under the row's `mid_conversation_system`
      # fact, else user text (the developer-role rule, normalize_role).
      def coerce_messages(input, options)
        entries = input.is_a?(Array) ? input : [{ role: "user", content: input }]
        entries = entries.map { |entry| entry.is_a?(Hash) ? Internal::Keys.shallow_stringify(entry) : { "role" => "user", "content" => entry } }

        system_segments = system_segments_from_instructions(options[:instructions])

        messages = []

        entries.each do |entry|
          if entry["role"].to_s == "system"
            if messages.empty? && !entry.key?("output_config")
              system_segments.concat(system_segments_from_message_content(entry["content"]))
            else
              append_system_update(messages, entry)
            end
            next
          end

          reject_non_assistant_after_system_update(messages, entry)
          append_entry(messages, entry)
        end

        [build_system(system_segments), messages]
      end

      # A non-leading system entry. Under the row fact it is the vendor's
      # in-place system message — text blocks (cache_control kept) and, for
      # the migration guide's effort-change recipe, an `output_config` on an
      # empty-content entry (F13's gem half; its beta follows the field).
      # Without the fact the text lowers in place to a user block; an
      # output_config entry has no lowering there and refuses.
      def append_system_update(messages, entry)
        blocks = system_segments_from_message_content(entry["content"]).filter_map { |segment| system_wire_block(segment) }
        output_config = entry["output_config"]

        if @mid_conversation_system
          return if blocks.empty? && output_config.nil?

          ensure_system_update_placement(messages)
          message = { role: "system", content: blocks }
          message[:output_config] = validated_system_output_config(output_config) unless output_config.nil?
          messages << message
        elsif output_config.nil?
          append_message(messages, role: "user", content: blocks)
        else
          raise SimpleInference::ValidationError,
                "a system entry carrying output_config has no lowering on this row: it is a " \
                "mid-conversation system message, which needs the row's mid_conversation_system fact"
        end
      end

      def validated_system_output_config(value)
        return Internal::Keys.shallow_symbolize(value) if value.is_a?(Hash) && !value.empty?

        raise SimpleInference::ValidationError,
              "a system entry's output_config must be a non-empty Hash (got #{value.inspect})"
      end

      # opencode's placement guard (anthropic-messages.ts canUseNativeSystemUpdate)
      # as a local refusal, since the vendor 400s the same shapes: the entry
      # must follow a user turn (tool results lower to one), so never
      # messages[0], never an assistant turn (an unanswered tool call
      # included), never another system message.
      def ensure_system_update_placement(messages)
        return if messages.last && messages.last[:role] == "user"

        raise SimpleInference::ValidationError,
              "a mid-conversation system entry must follow a user turn (or tool results) — never the first " \
              "message, never an assistant turn, never another system entry; the wire rejects these shapes"
      end

      # The other half of the guard: what follows an in-place system message
      # must be the assistant's turn (or the end of the input).
      def reject_non_assistant_after_system_update(messages, entry)
        return unless messages.last && messages.last[:role] == "system"
        return if entry["type"].to_s == "function_call"
        return if entry["type"].to_s != "function_call_output" && normalize_role(entry["role"]) == "assistant"

        raise SimpleInference::ValidationError,
              "the turn after a mid-conversation system entry must be the assistant's — a user turn or a " \
              "tool result there is a shape the wire rejects"
      end

      # instructions is a plain String (joined, cache off) or an Array of system
      # blocks the kernel marked with cache_control. Every segment becomes one
      # {"text", "cache_control"} pair; build_system decides the wire shape.
      def system_segments_from_instructions(instructions)
        case instructions
        when Array
          instructions.filter_map { |block| system_segment_from(block) }
        when nil
          []
        else
          [system_segment_from(instructions.to_s)].compact
        end
      end

      # A block is the caller's bare String or a {text, cache_control} Hash —
      # the declared union of the instructions array.
      def system_segment_from(block)
        case block
        when String
          block.strip.empty? ? nil : { "text" => block, "cache_control" => nil }
        when Hash
          normalized = Internal::Keys.shallow_stringify(block)
          text = normalized["text"].to_s
          text.empty? ? nil : { "text" => text, "cache_control" => normalized["cache_control"] }
        else
          nil
        end
      end

      def system_segments_from_message_content(content)
        case content
        when Array
          content.filter_map { |block| system_segment_from(block) }
        when Hash
          [system_segment_from(content)].compact
        else
          [system_segment_from(content.to_s)].compact
        end
      end

      # A String `system` when every segment is plain (byte-identical to the
      # pre-caching behaviour); a structured block array the moment one segment
      # carries cache_control. Returns nil when empty either way.
      def build_system(system_segments)
        return nil if system_segments.empty?

        if system_segments.none? { |segment| segment["cache_control"] }
          text = system_segments.map { |segment| segment["text"] }.join("\n\n").strip
          text.empty? ? nil : text
        else
          blocks = system_segments.filter_map { |segment| system_wire_block(segment) }
          blocks.empty? ? nil : blocks
        end
      end

      def system_wire_block(segment)
        return nil if segment["text"].strip.empty?

        block = { type: "text", text: segment["text"] }
        block[:cache_control] = segment["cache_control"] if segment["cache_control"]
        block
      end

      # Forward a caller-supplied cache_control from an already-normalized
      # source entry onto the freshly built wire block. Coverage is the block
      # types the kernel's placement can mark today — system/text/image/
      # tool_result; tools and tool_use passthrough is deliberately absent
      # (the kernel never marks them; a system-block marker already caches
      # tools, which render first), and thinking blocks reject cache_control
      # upstream (Anthropic 400).
      def with_cache_control(block, source)
        cache_control = source["cache_control"]
        cache_control ? block.merge(cache_control: cache_control) : block
      end

      def append_entry(messages, entry)
        if entry["type"].to_s == "function_call"
          append_message(
            messages,
            role: "assistant",
            content: [
              {
                type: "tool_use",
                id: wire_tool_id(entry["call_id"] || entry["id"]),
                name: entry["name"],
                input: parse_arguments(entry["arguments"]),
              }.compact,
            ]
          )
          return
        end

        if entry["type"].to_s == "function_call_output"
          append_message(
            messages,
            role: "user",
            content: [tool_result_block(entry, tool_use_id: entry["call_id"], content: entry["output"])]
          )
          return
        end

        role = normalize_role(entry["role"])
        content = normalize_message_content(entry)
        append_message(messages, role: role, content: content) if role && content.any?
      end

      # The ONE tool_result lowering for both input spellings. `is_error` is
      # the wire's own field (alignment 2026-09-16, F7 — opencode
      # anthropic-messages.ts:481, claude-code toolExecution.ts:480): the
      # neutral payload's flag lowers to it, absent when false; the text
      # marker the consumer puts in the content stays beside it, as
      # claude-code sends both.
      def tool_result_block(entry, tool_use_id:, content:)
        with_cache_control(
          {
            type: "tool_result",
            tool_use_id: wire_tool_id(tool_use_id),
            content: stringify_content(content),
            is_error: (true if entry["is_error"]),
          }.compact,
          entry
        )
      end

      # An unknown role is a loud refusal, never a passenger. This fell
      # through to `role.to_s` and `append_message` then put it on the wire
      # verbatim — so an unknown role reached Anthropic and came back a
      # 400. Its sibling lane already refused the same way ("unknown roles
      # are never relabeled"); this one simply never said so. `developer` is
      # the one KNOWN role of the sibling family with no twin on this wire:
      # it lowers to `user` so it stays WHERE THE CALLER PLACED IT in the
      # list — hoisting it into the system field would move it ahead of
      # everything behind it (Nexus S-F r2 (5)).
      def normalize_role(role)
        case role.to_s
        when "assistant", "model"
          "assistant"
        when "tool", "user", ""
          "user"
        when "developer"
          "user"
        else
          raise SimpleInference::ValidationError,
                "unsupported message role #{role.inspect} for anthropic messages " \
                "(accepted: #{ACCEPTED_ROLES.join(", ")}) — unknown roles are never relabeled"
        end
      end

      def normalize_message_content(entry)
        if entry["role"].to_s == "tool"
          return [tool_result_block(entry, tool_use_id: entry["tool_call_id"] || entry["call_id"], content: entry["content"])]
        end

        normalize_content_blocks(entry["content"]) + normalize_tool_call_blocks(entry["tool_calls"])
      end

      def normalize_content_blocks(content)
        case content
        when Array
          content.filter_map { |part| normalize_content_part(part) }
        when nil
          []
        else
          text = content.to_s
          text.empty? ? [] : [{ type: "text", text: text }]
        end
      end

      # A scalar part is the caller's shorthand for a text part — normalized
      # once here, at the lowering boundary.
      def normalize_content_part(part)
        return { type: "text", text: part.to_s } unless part.is_a?(Hash)

        normalized = Internal::Keys.shallow_stringify(part)
        type = normalized["type"].to_s

        case type
        when "", "text", "input_text", "output_text"
          text = normalized["text"].to_s
          text.empty? ? nil : with_cache_control({ type: "text", text: text }, normalized)
        when "input_image", "image", "image_url"
          with_cache_control(normalize_image_content_part(normalized), normalized)
        when "thinking"
          # Replayed prior-turn reasoning. Anthropic rejects a signature-less thinking
          # block (400), so drop the block rather than emit one that cannot validate.
          # EMPTY thinking text is a different matter: Claude 5's adaptive thinking
          # returns signature-only blocks (thinking: "", signature present) and the
          # continuation contract is replay-verbatim — live-probed 2026-08-29.
          thinking = normalized["thinking"].to_s
          signature = normalized["signature"].to_s
          return nil if signature.empty?

          { type: "thinking", thinking: thinking, signature: signature }
        when "redacted_thinking"
          # Opaque encrypted reasoning from a prior turn; the API expects it
          # replayed verbatim (reference: redacted_thinking_block_param.rb).
          { type: "redacted_thinking", data: normalized["data"].to_s }
        else
          raise SimpleInference::ValidationError, "unsupported anthropic content part #{type.inspect}"
        end
      end

      # Media ingress is BYTES-ONLY (transport policy, register Input-media
      # profiles v1): an image part carries a SimpleInference::MediaInput and
      # lowers to the `source.type: base64` wire block here — the lane builds
      # the base64 form from verified bytes itself. Caller data URIs, http(s)
      # URLs, host paths, and provider file handles are loud rejections at
      # this lowering — never forwarded, even though the Anthropic wire would
      # accept a url source.
      def normalize_image_content_part(part)
        media = image_media_carrier(part)
        unless media.is_a?(SimpleInference::MediaInput)
          raise SimpleInference::ValidationError,
                "anthropic image content parts carry raw bytes via SimpleInference::MediaInput — " \
                "caller data URIs, http(s) URLs, host paths, and provider file handles are " \
                "rejected at this lane's lowering (transport policy: prepared bytes embed " \
                "inline as base64; got #{media.class})"
        end

        {
          type: "image",
          source: {
            type: "base64",
            media_type: media.media_type,
            data: [media.bytes].pack("m0"),
          },
        }
      end

      # The carrier may arrive under the chat-family spelling (image_url,
      # possibly nested under "url") or the Anthropic-native source key; only
      # a MediaInput found there is acceptable, and unwrapping the nested
      # hash exposes string URL/data-URI carriers to the rejection above.
      def image_media_carrier(part)
        carrier = part["image_url"] || part["url"] || part["source"]
        carrier = carrier["url"] || carrier["data"] || carrier if carrier.is_a?(Hash)
        carrier
      end

      # Flat ({"name","arguments"}) or nested ({"function" => {...}}) calls.
      def normalize_tool_call_blocks(tool_calls)
        Array(tool_calls).map do |tool_call|
          normalized = Internal::Keys.shallow_stringify(tool_call)
          call_id = normalized["id"] || normalized["call_id"]
          function = normalized["function"].nil? ? normalized : Internal::Keys.shallow_stringify(normalized["function"])

          {
            type: "tool_use",
            id: wire_tool_id(call_id),
            name: function["name"],
            input: parse_arguments(function["arguments"] || normalized["arguments"]),
          }.compact
        end
      end

      def wire_tool_id(id) = id&.to_s&.gsub(TOOL_ID_REFUSED, "_")

      def append_message(messages, role:, content:)
        return if role.to_s.empty? || Array(content).empty?

        if messages.last&.fetch(:role, nil) == role
          messages.last[:content].concat(Array(content))
        else
          messages << {
            role: role,
            content: Array(content),
          }
        end
      end

      def normalize_tools(tools)
        Array(tools).filter_map do |tool|
          normalized = tool
          next unless normalized[:type] == "function"

          function = normalized[:function] || normalized

          # strict is a top-level tool field in the Anthropic API (reference:
          # tool.rb), not a JSON Schema keyword; accept the OpenAI-style flat
          # or nested placement and hoist it.
          strict = function.key?(:strict) ? function[:strict] : normalized[:strict]

          {
            name: function[:name],
            description: function[:description],
            input_schema: function[:parameters] || normalized[:parameters] || default_input_schema,
            strict: strict,
          }.compact
        end
      end

      def build_tool_choice(tool_choice:, parallel_tool_calls:)
        return nil if tool_choice.nil? && parallel_tool_calls.nil?

        normalized_choice = normalize_tool_choice(tool_choice)
        return nil if normalized_choice.nil? && parallel_tool_calls.nil?

        normalized_choice ||= "auto"
        choice = {
          type: case normalized_choice
                when "auto", "none"
                  normalized_choice
                when "required"
                  "any"
                else
                  "tool"
                end,
        }
        choice[:name] = normalized_choice if choice[:type] == "tool"
        choice[:disable_parallel_tool_use] = !parallel_tool_calls if !parallel_tool_calls.nil? && choice[:type] != "none"
        choice
      end

      def normalize_tool_choice(tool_choice)
        return nil if tool_choice.nil?

        # The wire's declared union: a mode string, or the function envelope.
        case tool_choice
        when Hash
          normalized = tool_choice
          type = normalized[:type]
          return normalized.dig(:function, :name) || normalized[:name] if type == "function"

          type if type.is_a?(String) && !type.empty?
        when String
          value = tool_choice
          value.empty? ? nil : value
        else
          nil
        end
      end

      def default_input_schema
        {
          type: "object",
          properties: {},
          required: [],
          additionalProperties: false,
        }
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
