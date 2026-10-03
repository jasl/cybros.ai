require "json"
require "uri"

require_relative "base"

module SimpleInference
  module Protocols
    # OpenAI Responses API protocol implementation.
    #
    # This protocol targets `POST /v1/responses` (or other configured path),
    # including SSE streaming (`text/event-stream`).
    class OpenAIResponses < Base
      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze

      # incomplete_reason is the DISTINCT surface for the response.incomplete
      # terminal's incomplete_details.reason — the body's status enum stays
      # the wire value ("incomplete") and is never overwritten with the reason.
      ResponsesResult = Data.define(:output_text, :output_items, :usage, :incomplete_reason, :response)

      # Typed failure surface for the response.failed terminal. The wire body
      # is EVIDENCE: provider error code/message ride as fields, and usage —
      # when the wire carried it — is retained (presence-vs-zero: absent wire
      # usage stays nil, never a fabricated zero hash).
      class ResponseFailedError < SimpleInference::Error
        attr_reader :code, :error_message, :usage, :response_body

        def initialize(message, code: nil, error_message: nil, usage: nil, response_body: nil)
          super(message)
          @code = code
          @error_message = error_message
          @usage = usage
          @response_body = response_body
        end
      end

      # Typed recognition for the bare `error` SSE event (the SSE event NAME
      # `error`, or a {"type":"error"} data payload) — documented alongside
      # the three response.* terminals; previously it fell through
      # unrecognized. Carries the full payload as evidence.
      class StreamErrorEventError < SimpleInference::Error
        attr_reader :payload

        def initialize(message, payload: nil)
          super(message)
          @payload = payload
        end
      end

      # Frozen wire vocabularies (reasoning contract row, source-conformance
      # register): effort none|minimal|low|medium|high|xhigh|max — per-model
      # subsets are a resource/catalog gate, not a wire gate — summary
      # auto|concise|detailed, and context auto|current_turn|all_turns (which
      # earlier turns' reasoning items the service renders into the next
      # sample). Out-of-set values are loud LOCAL rejections instead of
      # provider 400 round-trips.
      REASONING_EFFORT_VOCABULARY = %w[none minimal low medium high xhigh max].freeze
      REASONING_SUMMARY_VOCABULARY = %w[auto concise detailed].freeze
      REASONING_CONTEXT_VOCABULARY = %w[auto current_turn all_turns].freeze
      # `text.verbosity` (codex-rs codex-api/src/common.rs OpenAiVerbosity;
      # opencode textVerbosity): low|medium|high, folded beside
      # `text.format`. A per-model default is the catalog's row fact.
      VERBOSITY_VOCABULARY = %w[low medium high].freeze

      # Terminal SSE events that carry the full response body. response.failed
      # is also terminal but is surfaced as an error, not a body (see
      # raise_on_failed_stream_event).
      STREAM_TERMINAL_RESPONSE_EVENT_TYPES = [
        "response.completed".freeze,
        "response.incomplete".freeze,
      ].freeze

      # The fold over one Responses SSE stream: the text and usage seen so
      # far, the output items under assembly, and the terminal body once it
      # arrives (events_seen / last_event_type are the interruption evidence).
      class StreamFold
        attr_accessor :usage, :response_body, :terminal_status, :last_event_type
        attr_reader :output_text, :output_item_states, :output_item_order, :events_seen

        def initialize
          @output_text = +""
          @usage = nil
          @output_item_states = {}
          @output_item_order = []
          @response_body = nil
          @terminal_status = nil
          @events_seen = 0
          @last_event_type = nil
        end

        def count_event = @events_seen += 1

        def append_text(delta) = @output_text << delta
      end

      # The Responses API options this protocol PROCESSES by name (reasoning
      # nesting, response_format/verbosity->text, stateless-CoT store/include
      # defaults, stream forcing) or forwards 1:1 onto same-named wire fields.
      # :model and :input appear because responses_create/responses_stream
      # take the whole request as options. Provider-specific wire fields
      # ride extra_body. prompt_cache_key and service_tier are the two
      # request struct fields both references carry (codex-rs
      # ResponsesApiRequest, opencode openai-responses.ts) and forward 1:1;
      # which key and which tier is the caller's decision.
      def self.request_option_keys
        %i[
          model input stream
          instructions previous_response_id conversation
          tools tool_choice parallel_tool_calls
          response_format text verbosity
          reasoning reasoning_effort reasoning_summary
          include store
          prompt_cache_key service_tier
          max_output_tokens temperature top_p
        ].freeze
      end

      def initialize(responses_path: nil, **connection)
        super(**connection)
        @responses_path = normalize_responses_path(responses_path || "/v1/responses")
      end

      # POST /responses (non-streaming)
      def responses_create(**options)
        declared, extra_body = split_request_options(options)

        post_json(@responses_path, finalize_wire_body(responses_request_options(declared), extra_body))
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        compile_responses_request(
          model: model, input: input, stream: false, return_stream: false, options: options
        )
      end

      def compile_stream(model:, input:, **options)
        compile_responses_request(
          model: model, input: input, stream: true, return_stream: true, options: options
        )
      end

      # POST /responses (streaming)
      #
      # Yields parsed JSON events from an OpenAI-style SSE stream (`text/event-stream`).
      #
      # If no block is given, returns an Enumerator.
      def responses_stream(**options)
        return enum_for(:responses_stream, **options) unless block_given?

        declared, extra_body = split_request_options(options)
        body = responses_request_options(declared)
        body.delete(:stream)
        body[:stream] = true

        post_json_stream(@responses_path, finalize_wire_body(body, extra_body)) do |event_name, event|
          raise_on_error_stream_event(event_name, event)
          yield event
        end
      end

      # High-level helper for Responses API.
      #
      # - Non-streaming: returns ResponsesResult with `output_text` + `usage`.
      # - Streaming: yields `output_text` deltas to the block (if given), accumulates, and returns ResponsesResult.
      #
      # @yield [String] output_text delta chunks (streaming only)
      def responses(model:, input:, stream: nil, **options, &block)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        use_stream = stream.nil? ? block_given? : stream

        request = { model: model, input: coerce_responses_input(input) }.merge(declared)
        request.delete(:stream)

        if use_stream
          streamed_responses_result(request, extra_body: extra_body) do |event, _fold|
            delta = output_text_delta(event)
            block.call(delta) if delta && block
          end
        else
          response = responses_create(**request, extra_body: extra_body)
          responses_result_from_response(response)
        end
      end

      private

      def compile_responses_request(model:, input:, stream:, return_stream:, options:)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        request = { model: model, input: coerce_responses_input(input) }.merge(declared)
        request.delete(:stream)
        body = responses_request_options(request)
        body[:stream] = true if stream
        body = finalize_wire_body(body, extra_body)

        compile_json_request(path: @responses_path, body: body, stream: stream) do |connection_config, compiled|
          if stream
            compiled_stream = responses_stream_from_compiled(connection_config, compiled)
            return_stream ? compiled_stream : compiled_stream.final_result
          else
            response = compiled_response(compiled, config: connection_config)
            raw_result = responses_result_from_response(response)
            SimpleInference::Responses::Result.from_openai_responses(raw_result)
          end
        end
      end

      def responses_stream_from_compiled(connection_config, compiled)
        SimpleInference::Responses::Stream.new do |&emit|
          raw_result =
            streamed_responses_result_from_compiled(connection_config, compiled) do |event, fold|
              delta = output_text_delta(event)
              if delta
                emit.call(
                  SimpleInference::Responses::Events::TextDelta.new(
                    delta: delta
                  )
                )
              end

              reasoning_delta = reasoning_delta_from_event(event)
              if reasoning_delta
                emit.call(
                  SimpleInference::Responses::Events::ReasoningDelta.new(
                    delta: reasoning_delta.fetch(:delta),
                    kind: reasoning_delta.fetch(:kind),
                    item_id: reasoning_delta[:item_id]
                  )
                )
              end

              tool_event = stream_tool_call_event(event, states: fold.output_item_states)
              emit.call(tool_event) if tool_event
            end

          result = SimpleInference::Responses::Result.from_openai_responses(raw_result)
          emit.call(SimpleInference::Responses::Events::Completed.new(result: result))
          result
        end
      end

      def streamed_responses_result_from_compiled(connection_config, compiled)
        fold = StreamFold.new

        response = compiled_stream_response(compiled, config: connection_config) do |event_name, event|
          observed_event = normalized_stream_event(event)
          observe_stream_terminal(fold, event_name, observed_event)
          observe_stream_result(fold, observed_event)
          yield(observed_event, fold) if block_given?
        end

        responses_result_from_stream(response, fold)
      end

      def responses_result_from_response(response)
        body = response.body || {}
        ResponsesResult.new(
          output_text: output_text_from_body(body),
          output_items: output_items_from_body(body),
          usage: usage_from_body(body),
          incomplete_reason: incomplete_reason_from_body(body),
          response: response
        )
      end

      def normalize_responses_path(value)
        path = value.to_s.strip
        path = "/v1/responses" if path.empty?
        path = "/#{path}" unless path.start_with?("/")

        prefix = config.api_prefix.to_s
        return path if prefix.empty? || path.start_with?("#{prefix}/") || path == prefix
        return path unless config.base_url_included_api_prefix?

        "#{prefix}#{path}"
      end

      def responses_request_options(options)
        normalized = nested_reasoning_effort_options(options, default_summary: reasoning_summary_default)
        validate_reasoning_options(normalized[:reasoning])
        apply_reasoning_capture_defaults(normalized)
        if bytes_only_input_media_lane? && normalized[:input].is_a?(Array)
          normalized[:input] = lower_responses_input_media_items(normalized[:input])
        end
        normalized[:tools] = responses_wire_tools(normalized[:tools]) if normalized[:tools]
        fold_text_options(normalized)
      end

      # `text` is the wire's one container for BOTH the structured-output
      # format and the verbosity (codex-rs TextControls {verbosity, format}):
      # each folds in beside whatever the caller already put there, and no
      # object is invented when neither was given.
      def fold_text_options(normalized)
        response_format = delete_response_format_option(normalized)
        verbosity = normalized.delete(:verbosity)
        validate_verbosity(verbosity)
        return normalized if response_format.nil? && verbosity.nil?

        text_options = (normalized.delete(:text) || {}).transform_keys(&:to_s)
        text_options = text_options.merge("verbosity" => verbosity) unless verbosity.nil?
        text_options = text_options.merge("format" => response_format) unless response_format.nil?
        normalized[:text] = text_options
        normalized
      end

      def validate_verbosity(verbosity)
        return if verbosity.nil? || VERBOSITY_VOCABULARY.include?(verbosity.to_s)

        raise SimpleInference::ValidationError,
              "verbosity #{verbosity.inspect} is not in the frozen wire vocabulary " \
              "(#{VERBOSITY_VOCABULARY.join(", ")})"
      end

      # Lowering seams for family lanes whose wire drops an OpenAI-only
      # default (post-Stage-4 re-audit, fix 4): the summary default applied
      # when a caller sets an effort without one, and whether the
      # stateless-CoT capture defaults (store:false + encrypted-reasoning
      # include) apply at all. DeepSeek overrides both (its route never
      # generates summaries and supports no encrypted reasoning) and calls
      # `super` instead of copying this method.
      def reasoning_summary_default
        "auto"
      end

      def reasoning_capture_defaults?
        true
      end

      def delete_response_format_option(options)
        options.delete(:response_format)
      end

      # Media ingress is BYTES-ONLY for every Responses-family lane
      # (transport policy, register Input-media profiles v1): an input_image
      # part carries a SimpleInference::MediaInput and lowers to the inline
      # base64 data-URL wire form here — the data URL is CONSTRUCTED from
      # verified bytes, never caller-supplied. Caller data URIs, http(s)
      # URLs, host paths, and provider file ids are loud rejections at this
      # lowering. Subclasses inherit this transport lowering. A lane with its
      # own bytes-only lowering opts out (Codex), so already-lowered parts are
      # never processed twice.
      def bytes_only_input_media_lane?
        true
      end

      def lower_responses_input_media_items(items)
        items.map { |item| lower_responses_input_media_item(item) }
      end

      def lower_responses_input_media_item(item)
        item.to_h do |key, value|
          next [key, value] unless value.is_a?(Array) && %w[content output].include?(key.to_s)

          [key, value.map { |part| lower_responses_input_media_part(part) }]
        end
      end

      def lower_responses_input_media_part(part)
        return part unless responses_part_field(part, "type").to_s == "input_image"

        if part.key?("file_id") || part.key?(:file_id)
          raise SimpleInference::ValidationError,
                "openai input_image parts never carry provider file ids — provider file " \
                "handles are rejected by the transport policy (bytes-only ingress)"
        end

        media = responses_part_field(part, "image_url")
        unless media.is_a?(SimpleInference::MediaInput)
          raise SimpleInference::ValidationError,
                "openai input_image parts carry raw bytes via SimpleInference::MediaInput — " \
                "caller data URIs, http(s) URLs, host paths, and provider file handles are " \
                "rejected at this lane's lowering (got #{media.class})"
        end

        rest = part.reject { |key, _value| %w[type image_url].include?(key.to_s) }
        Internal::Keys.deep_stringify(rest).merge(
          "type" => "input_image",
          "image_url" => "data:#{media.media_type};base64,#{[media.bytes].pack("m0")}",
        )
      end

      # Reads a part field under either key spelling (kernel snapshots are
      # string-keyed, SDK callers may pass symbols) so a media carrier can
      # never slip past the rejection on a key-type technicality.
      def responses_part_field(hash, name)
        hash.key?(name) ? hash[name] : hash[name.to_sym]
      end

      # Overridable vocabulary seams: subclasses whose backend freezes a
      # different closed set (e.g. codex catalog-declared efforts) override
      # these rather than the validation itself.
      def reasoning_effort_vocabulary
        REASONING_EFFORT_VOCABULARY
      end

      def reasoning_summary_vocabulary
        REASONING_SUMMARY_VOCABULARY
      end

      def reasoning_context_vocabulary
        REASONING_CONTEXT_VOCABULARY
      end

      # Loud LOCAL rejection of out-of-set reasoning values (frozen register
      # vocabulary) — never forward a value the wire contract does not name.
      # Runs AFTER nested_reasoning_effort_options, so both the flat
      # reasoning_effort/reasoning_summary spellings and a caller-built
      # reasoning hash land here (symbol-keyed by that normalization).
      def validate_reasoning_options(reasoning)
        return if reasoning.nil?

        effort = reasoning[:effort]
        unless effort.nil? || reasoning_effort_vocabulary.include?(effort.to_s)
          raise SimpleInference::ValidationError,
                "reasoning.effort #{effort.inspect} is not in the frozen wire vocabulary " \
                "(#{reasoning_effort_vocabulary.join(", ")})"
        end

        summary = reasoning[:summary]
        unless summary.nil? || reasoning_summary_vocabulary.include?(summary.to_s)
          raise SimpleInference::ValidationError,
                "reasoning.summary #{summary.inspect} is not in the frozen wire vocabulary " \
                "(#{reasoning_summary_vocabulary.join(", ")}; pass reasoning_summary: \"none\" to omit it)"
        end

        context = reasoning[:context]
        return if context.nil? || reasoning_context_vocabulary.include?(context.to_s)

        raise SimpleInference::ValidationError,
              "reasoning.context #{context.inspect} is not in the frozen wire vocabulary " \
              "(#{reasoning_context_vocabulary.join(", ")})"
      end

      # The kernel emits chat-vocabulary input: canonical `input_text` parts for
      # every role, assistant messages carrying flat tool_calls
      # ({"id","name","arguments"}), and role:"tool" results. The Responses wire
      # has none of that vocabulary — assistant text must be `output_text`, and
      # tool splices must become function_call / function_call_output items.
      # String-keyed to match the kernel's snapshot; symbol-keyed SDK inputs
      # (with plain string content) are untouched. Reasoning items (role-less)
      # pass through unchanged.
      def coerce_responses_input(input)
        return input unless input.is_a?(Array)

        input.flat_map do |item|
          case item["role"].to_s
          when "assistant"
            coerce_assistant_input_item(item)
          when "tool"
            [function_call_output_item(item)]
          else
            [wire_item(item)]
          end
        end
      end

      # A tool result's `is_error` is the kernel's neutral flag (Anthropic's
      # tool_result field); this wire has no such parameter and answers 400
      # "Unknown parameter: 'input[n].is_error'". The output text carries
      # the kernel's error marker, so the model still reads the failure.
      def wire_item(item)
        item["type"].to_s == "function_call_output" ? item.except("is_error") : item
      end

      def coerce_assistant_input_item(item)
        calls = item["tool_calls"]
        message = calls ? item.reject { |key, _| key == "tool_calls" } : item
        content = message["content"]
        message = message.merge("content" => content.map { |part| coerce_assistant_text_part(part) }) if content.is_a?(Array)
        return [message] unless calls

        items = assistant_message_content?(message["content"]) ? [message] : []
        items + calls.filter_map { |call| function_call_item(call) }
      end

      # A tool-call round's assistant shell often has no text; the Responses
      # API rejects an empty message item, so emit only the function_call items.
      def assistant_message_content?(content)
        case content
        when Array then content.any?
        when nil then false
        else !content.to_s.empty?
        end
      end

      # Flat ({"name","arguments"}) or nested ({"function" => {...}}) calls.
      def function_call_item(call)
        function = call["function"] || call
        name = function["name"].to_s
        return nil if name.empty?

        {
          "type" => "function_call",
          "call_id" => (call["call_id"] || call["id"]).to_s,
          "name" => name,
          "arguments" => function_call_arguments_string(function["arguments"] || call["arguments"]),
        }
      end

      def function_call_output_item(item)
        {
          "type" => "function_call_output",
          "call_id" => (item["tool_call_id"] || item["call_id"]).to_s,
          "output" => function_call_output_string(item["content"]),
        }
      end

      def function_call_arguments_string(arguments)
        return "{}" if arguments.nil?
        return arguments if arguments.is_a?(String)

        JSON.generate(arguments)
      end

      def function_call_output_string(content)
        return content if content.is_a?(String)

        if content.is_a?(Array)
          texts = content.filter_map { |part| part["text"] }
          return texts.join unless texts.empty?
        end

        content.nil? ? "" : JSON.generate(content)
      end

      def coerce_assistant_text_part(part)
        return part unless part["type"].to_s == "input_text"

        part.merge("type" => "output_text")
      end

      # The kernel advertises tools in the chat-completions nested shape (its
      # canonical form); the Responses API requires the flat function shape and
      # 400s on the envelope ("Missing required parameter: 'tools[0].name'").
      # Flat function entries and built-in (non-function) tools pass through.
      def responses_wire_tools(tools)
        tools.map do |tool|
          normalized = Internal::Keys.deep_stringify(tool)
          function = normalized["function"]
          next normalized unless normalized["type"].to_s == "function" && function

          {
            "type" => "function",
            "name" => function["name"],
            "description" => function["description"],
            "parameters" => function["parameters"],
            "strict" => function.key?("strict") ? function["strict"] : normalized["strict"],
          }.compact
        end
      end

      # When reasoning is requested, capture it statelessly so it can be replayed on later
      # turns: ask for the encrypted reasoning blob and don't retain server-side state.
      # Caller-provided store/include are respected. Gated on the
      # reasoning_capture_defaults? seam — a lane whose wire has no
      # encrypted-reasoning capture (DeepSeek) turns it off there.
      def apply_reasoning_capture_defaults(options)
        return unless reasoning_capture_defaults?
        # `options` is normalized by nested_reasoning_effort_options to symbol keys.
        return unless options[:reasoning]

        options[:store] = false unless options.key?(:store)
        includes = Array(options[:include]).map(&:to_s)
        options[:include] = (includes + ["reasoning.encrypted_content"]).uniq
      end

      def streamed_responses_result(request, extra_body: {})
        fold = StreamFold.new

        response =
          responses_stream(**request, extra_body: extra_body) do |event|
            observe_stream_terminal(fold, nil, event)
            observe_stream_result(fold, event)
            yield(event, fold) if block_given?
          end

        responses_result_from_stream(response, fold)
      end

      def observe_stream_result(fold, event)
        delta = output_text_delta(event)
        fold.append_text(delta) if delta

        usage = usage_from_event(event)
        fold.usage = usage if usage
        collect_output_item_event(event, states: fold.output_item_states, order: fold.output_item_order)
      end

      def responses_result_from_stream(response, fold)
        output_items = finalize_stream_output_items(fold.output_item_states, fold.output_item_order)
        full = fold.output_text
        last_usage = fold.usage
        response_body = validated_responses_stream_body(response, fold)
        response = response.with(body: response_body) if response.body.nil?
        body_output_items = output_items_from_body(response_body)
        output_items = merge_stream_output_items_with_body(output_items, body_output_items) if body_output_items.any?
        output_items = body_output_items if output_items.empty?
        full = output_text_from_body(response_body) if full.empty?
        last_usage ||= usage_from_body(response_body)

        ResponsesResult.new(
          output_text: full,
          output_items: output_items,
          usage: last_usage,
          incomplete_reason: incomplete_reason_from_body(response_body),
          response: response
        )
      end

      def observe_stream_terminal(fold, event_name, event)
        fold.count_event
        event_type = event["type"].to_s
        fold.last_event_type = event_type unless event_type.empty?
        raise_on_error_stream_event(event_name, event)
        raise_on_failed_stream_event(event)

        response_body = terminal_response_body_from_event(event)
        unless response_body.nil?
          fold.response_body = response_body
          fold.terminal_status = event_type.delete_prefix("response.")
        end
      end

      def validated_responses_stream_body(response, fold)
        stream_response_body(
          response, fold.response_body,
          events_seen: fold.events_seen, last_event_type: fold.last_event_type
        )
      end

      def normalized_stream_event(event)
        event
      end

      def stream_tool_call_event(event, states:)
        case event["type"].to_s
        when "response.function_call_arguments.delta"
          key = event["item_id"].to_s.strip
          return nil if key.empty?

          state = states[key] || {}
          SimpleInference::Responses::Events::ToolCallDelta.new(
            item_id: key,
            call_id: state["call_id"],
            name: state["name"],
            delta: event["delta"]
          )
        when "response.function_call_arguments.done"
          key = event["item_id"].to_s.strip
          return nil if key.empty?

          state = states[key] || {}
          SimpleInference::Responses::Events::ToolCallDone.new(
            item_id: key,
            call_id: state["call_id"],
            name: state["name"],
            arguments: state["arguments"].to_s
          )
        else
          nil
        end
      end

      def base_url
        config.base_url
      end

      def post_json(path, body, raise_on_http_error: nil)
        request_json(
          method: :post,
          url: "#{base_url}#{path}",
          headers: wire_headers(body),
          body: body,
          expect_json: true,
          raise_on_http_error: raise_on_http_error,
        )
      end

      def output_text_delta(event)
        case event["type"].to_s
        when "response.output_text.delta"
          event["delta"].to_s
        else
          nil
        end
      end

      def reasoning_delta_from_event(event)
        type = event["type"].to_s
        kind =
          case type
          when "response.reasoning_text.delta"
            "reasoning_text"
          # Providers spell the summary delta two ways on live streams:
          # `response.reasoning_summary_text.delta` (OpenAI SDKs) and
          # `response.reasoning_summary.delta` (seen in the wild; opencode
          # handles both). Same payload shape, same kind.
          when "response.reasoning_summary_text.delta", "response.reasoning_summary.delta"
            "reasoning_summary"
          else
            return nil
          end

        delta = event["delta"].to_s
        return nil if delta.empty?

        {
          delta: delta,
          kind: kind,
          item_id: event["item_id"],
        }
      end

      # Usage is TERMINAL-ONLY on this wire (null on in-progress snapshots).
      # response.incomplete carrying fully populated usage is probe-verified
      # (2026-08-09) — recognize it alongside response.completed. Absent wire
      # usage stays nil: never fabricate a zero hash (presence-vs-zero).
      def usage_from_event(event)
        case event["type"].to_s
        when "response.completed", "response.incomplete"
          response = event["response"]
          usage = (response.is_a?(Hash) ? response["usage"] : nil) || event["usage"]
          usage_with_served_tier(usage, response)
        else
          nil
        end
      end

      # THE TIER THAT WAS SERVED rides the usage record (opencode
      # openai-responses.ts reads `response.service_tier` back): a request
      # for flex/auto can be served at another tier, so accounting keys on
      # the response's word, never the request's. Absent on the wire, absent
      # here — the usage hash is otherwise the wire's own object.
      def usage_with_served_tier(usage, response_body)
        return usage unless usage.is_a?(Hash) && response_body.is_a?(Hash)

        tier = response_body["service_tier"]
        return usage if tier.nil? || tier.to_s.empty?

        usage.merge("service_tier" => tier)
      end

      # response.completed AND response.incomplete are terminal events carrying
      # the full response body (usage, partial output). The body is kept
      # VERBATIM: `status` stays the wire status enum ("completed" /
      # "incomplete") and the cutoff cause stays where the wire put it —
      # incomplete_details.reason — surfaced as the DISTINCT
      # ResponsesResult#incomplete_reason field, never merged over the enum.
      def terminal_response_body_from_event(event)
        type = event["type"].to_s
        return nil unless STREAM_TERMINAL_RESPONSE_EVENT_TYPES.include?(type)

        event["response"] || {}
      end

      # The DISTINCT incomplete-cutoff surface (e.g. "max_output_tokens");
      # nil whenever the wire carried no incomplete_details.reason.
      def incomplete_reason_from_body(body)
        reason = body.dig("incomplete_details", "reason")
        reason.nil? || reason.to_s.empty? ? nil : reason
      end

      # response.failed is a terminal event whose body carries the error
      # payload; raise it typed with the provider's code + message — and
      # RETAIN wire usage when present, the served tier merged as on the
      # other terminals (billing evidence rides the failure surface; absent
      # usage stays nil) — instead of letting the stream fall through to the
      # generic no-terminal interruption error.
      def raise_on_failed_stream_event(event)
        return unless event["type"].to_s == "response.failed"

        response = event["response"] || {}
        error = response["error"] || {}
        usage = usage_with_served_tier(response["usage"], response)
        details = [error["code"], error["message"]].reject { |value| value.to_s.empty? }

        message = "responses stream reported response.failed"
        message = "#{message}: #{details.join(" - ")}" if details.any?
        raise ResponseFailedError.new(
          message,
          code: error["code"],
          error_message: error["message"],
          usage: usage,
          response_body: response
        )
      end

      # Bare `error` SSE events — the SSE event NAME `error`, or a
      # {"type":"error"} data payload (code/message at top level, or nested
      # under "error" from proxying gateways) — get typed recognition
      # carrying the payload instead of falling through unrecognized.
      def raise_on_error_stream_event(event_name, event)
        return unless event_name.to_s == "error" || event["type"].to_s == "error"

        error = event["error"] || event
        details = [error["code"], error["message"]].reject { |value| value.to_s.empty? }

        message = "responses stream reported an error event"
        message = "#{message}: #{details.join(" - ")}" if details.any?
        raise StreamErrorEventError.new(message, payload: event)
      end

      # A 2xx SSE stream that ends WITHOUT any terminal event
      # (response.completed / response.incomplete / response.failed) is an
      # INTERRUPTION — loud and typed (the SHARED cross-protocol
      # ProviderStreamInterruptedError), never a silent partial result.
      def stream_response_body(response, completed_response_body, events_seen: nil, last_event_type: nil)
        return response.body if response.body
        return completed_response_body if completed_response_body

        raise SimpleInference::ProviderStreamInterruptedError.new(
          "responses stream interrupted: ended before a terminal event " \
          "(response.completed / response.incomplete / response.failed)",
          events_seen: events_seen,
          last_event_type: last_event_type,
        )
      end

      def collect_output_item_event(event, states:, order:)
        case event["type"].to_s
        when "response.output_item.added"
          item = event["item"]
          return if item.nil?

          key = output_item_key(item, fallback: event["item_id"])
          return if key.nil?

          existing = states[key] || {}
          normalized = normalize_output_item_hash(item)
          merged = existing.merge(normalized)
          merged["arguments"] = existing["arguments"].to_s if normalized["type"].to_s == "function_call" && normalized["arguments"].to_s.empty? && existing["arguments"]
          merged["output_index"] = Integer(event["output_index"], exception: false) || existing["output_index"]
          states[key] = merged
          order << key unless order.include?(key)
        when "response.output_item.done"
          item = event["item"]
          return if item.nil?

          key = output_item_key(item, fallback: event["item_id"])
          return if key.nil?

          existing = states[key] || {}
          normalized = normalize_output_item_hash(item)
          merged = existing.merge(normalized)
          merged["arguments"] = existing["arguments"].to_s if normalized["type"].to_s == "function_call" && normalized["arguments"].to_s.empty? && existing["arguments"]
          merged["output_index"] = Integer(event["output_index"], exception: false) || existing["output_index"]
          states[key] = merged
          order << key unless order.include?(key)
        when "response.function_call_arguments.delta"
          key = event["item_id"].to_s.strip
          return if key.empty?

          state = states[key] ||= { "type" => "function_call", "id" => key, "arguments" => "" }
          state["output_index"] ||= Integer(event["output_index"], exception: false)
          state["name"] ||= event["name"].to_s unless event["name"].to_s.empty?
          state["arguments"] = state["arguments"].to_s + event["delta"].to_s
          order << key unless order.include?(key)
        when "response.function_call_arguments.done"
          key = event["item_id"].to_s.strip
          return if key.empty?

          state = states[key] ||= { "type" => "function_call", "id" => key, "arguments" => "" }
          state["output_index"] ||= Integer(event["output_index"], exception: false)
          state["name"] ||= event["name"].to_s unless event["name"].to_s.empty?
          args = event["arguments"].to_s
          state["arguments"] = args unless args.empty?
          order << key unless order.include?(key)
        else
          nil
        end
      end

      def finalize_stream_output_items(states, order)
        order
          .filter_map { |key| states[key] }
          .sort_by.with_index { |item, idx| [item["output_index"] || Float::INFINITY, idx] }
          .map do |item|
            item.reject { |key, _| key == "output_index" }
          end
      end

      def output_item_key(item, fallback:)
        id = item["id"].to_s.strip
        return id unless id.empty?

        fallback_id = fallback.to_s.strip
        return nil if fallback_id.empty?

        fallback_id
      end

      def normalize_output_item_hash(item)
        item.each_with_object({}) do |(key, value), out|
          out[key.to_s] = value
        end
      end

      def merge_stream_output_items_with_body(stream_items, body_items)
        candidates = Array(body_items)
        # Each body item may enrich exactly ONE stream item. Identical parallel
        # calls (same name, same arguments) would otherwise all shape-match the
        # first body item and share its call_id — leaving the sibling call_ids
        # unassigned and the calls unanswerable. Claimed candidates drop out, so
        # identical calls pair positionally with the body's output order.
        claimed = []

        Array(stream_items).map do |item|
          next item unless item["type"].to_s == "function_call"

          body_index =
            candidates.each_index.find do |candidate_index|
              next false if claimed.include?(candidate_index)

              candidate = candidates.fetch(candidate_index)
              next false unless candidate["type"].to_s == "function_call"

              candidate_call_id = candidate["call_id"].to_s.strip
              candidate_id = candidate["id"].to_s.strip
              item_call_id = item["call_id"].to_s.strip
              item_id = item["id"].to_s.strip
              # Identifier matches require a NON-EMPTY operand: two id-less
              # items must never count as "same id" via "" == "".
              same_id =
                (!item_call_id.empty? && candidate_call_id == item_call_id) ||
                (!item_id.empty? && candidate_id == item_id) ||
                (!item_id.empty? && candidate_call_id == item_id)
              same_shape =
                candidate["name"].to_s == item["name"].to_s &&
                  candidate["arguments"].to_s == item["arguments"].to_s
              same_id || same_shape
            end

          next item unless body_index

          claimed << body_index
          body_item = candidates.fetch(body_index)
          item.merge(
            "id" => body_item["id"].to_s.strip.empty? ? item["id"] : body_item["id"],
            "call_id" => body_item["call_id"].to_s.strip.empty? ? item["call_id"] : body_item["call_id"],
            "name" => body_item["name"].to_s.strip.empty? ? item["name"] : body_item["name"],
            "arguments" => body_item["arguments"].to_s.strip.empty? ? item["arguments"] : body_item["arguments"],
          )
        end
      end

      def output_text_from_body(body)
        output_items_from_body(body).flat_map do |item|
          Array(item["content"]).filter_map do |part|
            part["text"].to_s if part["type"].to_s == "output_text"
          end
        end.join
      end

      def output_items_from_body(body)
        Array(body["output"])
      end

      def usage_from_body(body)
        usage_with_served_tier(body["usage"], body)
      end
    end
  end
end
