require_relative "openai_compatible"

module SimpleInference
  module Protocols
    # The PLAIN OpenAI-compatible translator: a Responses-shaped surface over
    # the /chat/completions wire, for third-party hosts that speak the
    # OpenAI-compatible dialect without broker extensions. Registered as its
    # own adapter identity `openai_compatible_chat` (post-Stage-4 re-audit,
    # fix 3) so such a host can become a registry row; OpenRouter subclasses
    # this for its broker-specific wire facts.
    class OpenAICompatibleResponses < OpenAICompatible
      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze

      # Whether streamed requests ask for the final usage chunk via
      # stream_options.include_usage is a CONSTRUCTION fact about the lane,
      # never a hidden per-request default: providers whose usage accounting
      # is always-on (OpenRouter) must never see the deprecated opt-in field.
      # The RESPONSES-level surface vocabulary, in two groups:
      # - options this adapter TRANSLATES before they hit the chat engine
      #   (instructions -> system message, max_output_tokens -> max_tokens,
      #   response_format/tools/tool_choice -> chat-completions envelopes,
      #   stream_options -> usage injection),
      # - standard OpenAI chat-completions params forwarded by name onto the
      #   /chat/completions wire.
      # Provider-specific wire fields ride extra_body.
      def self.request_option_keys
        %i[
          instructions max_output_tokens response_format tools tool_choice
          stream_options
          audio frequency_penalty logit_bias logprobs max_completion_tokens
          max_tokens metadata modalities n parallel_tool_calls prediction
          presence_penalty reasoning_effort seed service_tier stop store
          temperature top_logprobs top_p user
        ].freeze
      end

      def initialize(stream_include_usage: nil, **connection)
        super(**connection)
        @stream_include_usage = validated_stream_include_usage(stream_include_usage)
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(
          { model: model, messages: coerce_messages(input, declared) }.merge(chat_options(declared)),
          extra_body
        )

        compile_json_request(path: api_path("/chat/completions"), body: body, stream: false) do |connection_config, compiled|
          observation = new_wire_observation
          raw_result = chat_result_from_response(compiled_response(compiled, config: connection_config))
          observe_terminal_body(observation, raw_result.response&.body)
          chat_result_from(raw_result, observation)
        end
      end

      def compile_stream(model:, input:, **options)
        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(
          { model: model, messages: coerce_messages(input, declared) }.merge(stream_chat_options(declared)),
          extra_body
        )
        body["stream"] = true

        compile_json_request(path: api_path("/chat/completions"), body: body, stream: true) do |connection_config, compiled|
          stream_from_compiled(connection_config, compiled)
        end
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def stream_from_compiled(connection_config, compiled)
        SimpleInference::Responses::Stream.new do |&emit|
          observation = new_wire_observation
          full = +""
          reasoning_content = +""
          refusal = +""
          finish_reason = nil
          last_usage = nil
          collected_logprobs = []
          streamed_tool_calls = []
          emitted_done = {}
          events_seen = 0
          last_event_type = nil

          raw_response =
            compiled_stream_response(compiled, config: connection_config) do |_event_name, event|
              raise_on_mid_stream_error_event(event)
              events_seen += 1
              last_event_type = event["object"].to_s
              observe_stream_event(observation, event)

              delta = OpenAI.chat_completion_chunk_delta(event)
              if delta
                full << delta
                emit.call(
                  SimpleInference::Responses::Events::TextDelta.new(
                    delta: delta
                  )
                )
              end
              reasoning_delta = OpenAI.chat_completion_chunk_reasoning_delta(event)
              if reasoning_delta
                reasoning_content << reasoning_delta
                emit.call(
                  SimpleInference::Responses::Events::ReasoningDelta.new(
                    delta: reasoning_delta,
                    kind: "reasoning_text"
                  )
                )
              end

              # The model declining streams as `delta.refusal`: folded into
              # the message's refusal, never emitted as the answer's text.
              refusal_delta = OpenAI.chat_completion_chunk_refusal_delta(event)
              refusal << refusal_delta if refusal_delta

              chunk_finish_reason = event.dig("choices", 0, "finish_reason")
              finish_reason = chunk_finish_reason unless chunk_finish_reason.to_s.empty?

              collected_logprobs.concat(Array(event.dig("choices", 0, "logprobs", "content")))

              usage = OpenAI.chat_completion_usage(event)
              last_usage = usage if usage

              merge_stream_tool_calls(streamed_tool_calls, event)
              emit_stream_tool_call_events(
                emit: emit,
                event: event,
                streamed_tool_calls: streamed_tool_calls,
                emitted_done: emitted_done
              )
            end

          if raw_response.success? && !raw_response.body.nil?
            raise SimpleInference::ProviderStreamInterruptedError.new(
              "stream request returned a non-SSE success response (HTTP #{raw_response.status}); " \
              "streaming support is a profile capability fact — refusing to synthesize a " \
              "stream from a buffered body",
              events_seen: 0,
              last_event_type: nil
            )
          end

          response_usage = last_usage || OpenAI.chat_completion_usage(raw_response)
          response_finish_reason = finish_reason || OpenAI.chat_completion_finish_reason(raw_response)
          ensure_chat_stream_terminal(
            raw_response, response_finish_reason,
            events_seen: events_seen, last_event_type: last_event_type
          )
          synthesized_body = synthesize_stream_chat_completion_body(
            content: full,
            reasoning_content: reasoning_content,
            refusal: refusal,
            finish_reason: response_finish_reason,
            usage: response_usage,
            logprobs: collected_logprobs,
            tool_calls: streamed_tool_calls
          )
          extras = synthesized_message_extras(observation)
          unless extras.empty?
            message = synthesized_body.dig("choices", 0, "message") || {}
            synthesized_body["choices"][0]["message"] = message.merge(extras)
          end
          raw_response = Response.new(
            status: raw_response.status,
            headers: raw_response.headers,
            body: raw_response.body || synthesized_body,
            raw_body: raw_response.raw_body
          )
          emit_remaining_stream_tool_call_done_events(
            emit: emit,
            streamed_tool_calls: streamed_tool_calls,
            emitted_done: emitted_done
          )

          raw_result = OpenAI::ChatResult.new(
            content: full,
            usage: response_usage,
            finish_reason: response_finish_reason,
            logprobs: collected_logprobs.empty? ? OpenAI.chat_completion_logprobs(raw_response) : collected_logprobs,
            response: raw_response
          )
          result = chat_result_from(raw_result, observation)
          emit.call(SimpleInference::Responses::Events::Completed.new(result: result))
          result
        end
      end

      private

      def validated_stream_include_usage(value)
        return true if value.nil?
        return value if value == true || value == false

        raise SimpleInference::ConfigurationError,
              "stream_include_usage must be true or false (got #{value.inspect})"
      end

      def stream_include_usage? = @stream_include_usage

      # --- lane observation hooks ---
      #
      # Subclasses whose wire carries terminal facts beyond the plain
      # chat-completions shape (OpenRouter: cost/BYOK/native finish reason/
      # broker metadata/reasoning_details) override these four hooks; the
      # shared create/stream engines call them at the same seams so a lane
      # never re-implements the streaming loop just to observe extra fields.

      def new_wire_observation
        nil
      end

      def observe_stream_event(_observation, _event)
        nil
      end

      def observe_terminal_body(_observation, _body)
        nil
      end

      # Extra string-keyed fields merged onto the SYNTHESIZED assistant
      # message a completed stream reconstructs (the real terminal body only
      # exists on the non-streaming path).
      def synthesized_message_extras(_observation)
        {}
      end

      def chat_result_from(raw_result, _observation)
        SimpleInference::Responses::Result.from_openai_chat(raw_result)
      end

      def coerce_messages(input, options)
        responses_messages_for(input, options)
      end

      def chat_options(options)
        normalized = options.each_with_object({}) do |(key, value), out|
          next if key == :instructions

          normalized_key = key == :max_output_tokens ? :max_tokens : key
          out[normalized_key] =
            case key
            when :response_format
              chat_response_format(value)
            when :tools
              chat_tools(value)
            when :tool_choice
              chat_tool_choice(value)
            else
              value
            end
        end

        normalized
      end

      # response_format and tool_choice are the wire's declared unions (a
      # string form such as tool_choice "auto"/"none"/"required", or the
      # Responses-style object); only the object form is reshaped here.
      def chat_response_format(value)
        normalized = value
        return normalized unless normalized.is_a?(Hash) && normalized[:type] == "json_schema"

        json_schema = normalized.slice(:name, :schema, :strict).compact
        return normalized if json_schema.empty?

        { type: "json_schema", json_schema: json_schema }
      end

      def chat_tools(value)
        return value unless value.is_a?(Array)

        value.map { |tool| chat_tool(tool) }
      end

      def chat_tool(value)
        return value unless value[:type] == "function"

        function = value.slice(:name, :description, :parameters, :strict).compact
        return value if function.empty?

        { type: "function", function: function }
      end

      def chat_tool_choice(value)
        normalized = value
        return normalized unless normalized.is_a?(Hash) && normalized[:type] == "function"

        name = normalized[:name]
        return normalized unless name.is_a?(String) && !name.empty?

        { type: "function", function: { name: name } }
      end

      # The construction-time usage opt-in: injected only when the lane was
      # built with stream_include_usage (the default for generic OpenAI-
      # compatible gateways, whose final usage chunk never arrives without it).
      def stream_chat_options(options)
        normalized = chat_options(options)
        return normalized unless stream_include_usage?

        stream_options = (normalized[:stream_options] || {}).dup
        stream_options[:include_usage] = true unless stream_options.key?(:include_usage)
        normalized[:stream_options] = stream_options
        normalized
      end
    end
  end
end
