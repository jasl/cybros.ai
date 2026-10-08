require_relative "base"

module SimpleInference
  module Protocols
    # Pi's transcript transport: one JSON request and an SSE stream of typed
    # assistant events. The backend, rather than this client, routes the model.
    class PiMessages < Base
      require_relative "pi_messages/request_body"
      include RequestBody

      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze
      REASONING_EFFORTS = %w[none minimal low medium high xhigh max].freeze

      def initialize(provider_id: "pi", messages_path: "/messages", **connection)
        super(**connection)
        @provider_id = provider_id.to_s
        @messages_path = messages_path.to_s
        raise ConfigurationError, "messages_path must start with /" unless @messages_path.start_with?("/")
      end

      # The selected provider is profile identity, never a model wire option.
      def self.protocol_option_keys = super - [:provider_id]

      def self.request_option_keys
        %i[max_output_tokens temperature instructions tools tool_choice reasoning_enabled reasoning_effort
          cache_retention session_id].freeze
      end

      def create(model:, input:, **options)
        stream(model: model, input: input, **options).final_result
      end

      def compile_create(model:, input:, **options)
        compile(model: model, input: input, **options) { |stream| stream.final_result }
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def compile_stream(model:, input:, **options)
        compile(model: model, input: input, **options) { |stream| stream }
      end

      private

      def compile(model:, input:, **options, &consume)
        raise ValidationError, "model is required" if model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(build_request_body(model: model, input: input, options: declared), extra_body)
        compile_json_request(path: @messages_path, body: body, stream: true) do |connection, compiled|
          consume.call(response_stream(connection, compiled))
        end
      end

      def response_stream(connection, compiled)
        Responses::Stream.new do |&emit|
          state = { blocks: {}, started: false, terminal: nil, count: 0, last: nil }
          response = compiled_stream_response(compiled, config: connection) do |_name, event|
            next if state[:terminal]

            state[:count] += 1
            state[:last] = event.fetch("type")
            apply_event(state, event, emit)
          end
          unless state[:terminal]
            raise ProviderStreamInterruptedError.new("pi_messages stream ended without done or error",
              events_seen: state[:count], last_event_type: state[:last])
          end

          result = result_for(state, response)
          emit.call(Responses::Events::Completed.new(result: result))
          result
        end
      end

      def apply_event(state, event, emit)
        type = event.fetch("type")
        if type == "error"
          raise StreamError, event.fetch("errorMessage", "pi_messages provider #{event.fetch("reason")}")
        end
        if type == "start"
          raise DecodeError, "duplicate pi_messages start" if state[:started]

          state[:started] = true
          return
        end
        raise DecodeError, "pi_messages #{type} arrived before start" unless state[:started]

        if type == "done"
          reason = event.fetch("reason")
          raise DecodeError, "unknown pi_messages finish #{reason.inspect}" unless %w[stop length toolUse].include?(reason)

          state[:terminal] = event
          return
        end
        index = Integer(event.fetch("contentIndex"))
        raise DecodeError, "negative pi_messages contentIndex" if index.negative?

        blocks = state.fetch(:blocks)
        case type
        when "text_start" then blocks[index] = { "type" => "text", "text" => "" }
        when "thinking_start" then blocks[index] = { "type" => "thinking", "thinking" => "" }
        when "toolcall_start"
          blocks[index] = { "type" => "toolCall", "id" => event.fetch("id"),
            "name" => event.fetch("toolName"), "arguments" => {}, "partial_json" => "" }
        when "text_delta"
          block = expected_block(blocks, index, "text")
          delta = event.fetch("delta").to_s
          block["text"] += delta
          emit.call(Responses::Events::TextDelta.new(delta: delta))
        when "thinking_delta"
          block = expected_block(blocks, index, "thinking")
          delta = event.fetch("delta").to_s
          block["thinking"] += delta
          emit.call(Responses::Events::ReasoningDelta.new(delta: delta, kind: "thinking", item_id: index.to_s))
        when "toolcall_delta"
          block = expected_block(blocks, index, "toolCall")
          delta = event.fetch("delta").to_s
          block["partial_json"] += delta
          emit.call(Responses::Events::ToolCallDelta.new(item_id: block.fetch("id"), call_id: block.fetch("id"),
            name: block.fetch("name"), delta: delta))
        when "text_end"
          block = expected_block(blocks, index, "text")
          block.merge!("text" => event.fetch("content"), "textSignature" => event["contentSignature"])
        when "thinking_end"
          block = expected_block(blocks, index, "thinking")
          block.merge!("thinking" => event.fetch("content"), "thinkingSignature" => event["contentSignature"],
            "redacted" => event["redacted"])
        when "toolcall_end"
          block = expected_block(blocks, index, "toolCall")
          call = event.fetch("toolCall").to_h
          unless call.fetch("id") == block.fetch("id") && call.fetch("name") == block.fetch("name")
            raise DecodeError, "pi_messages tool call changed its identity"
          end
          block.merge!(call).delete("partial_json")
          emit.call(Responses::Events::ToolCallDone.new(item_id: block.fetch("id"), call_id: block.fetch("id"),
            name: block.fetch("name"), arguments: JSON.generate(block.fetch("arguments").to_h)))
        else raise DecodeError, "unknown pi_messages event #{type.inspect}"
        end
      end

      def expected_block(blocks, index, type)
        block = blocks.fetch(index) { raise DecodeError, "pi_messages block #{index} has not started" }
        raise DecodeError, "pi_messages block #{index} is not #{type}" unless block.fetch("type") == type

        block
      end

      def result_for(state, response)
        terminal = state.fetch(:terminal)
        blocks = state.fetch(:blocks).sort.map(&:last)
        items = blocks.map { |block| output_item(block) }
        Responses::Result.new(id: terminal["responseId"], output_text: blocks.filter_map { |block| block["text"] }.join,
          output_items: items, tool_calls: Responses::Result.tool_calls_from_output_items(items),
          usage: normalize_usage(terminal.fetch("usage")), finish_reason: terminal.fetch("reason"),
          finish_detail: terminal.fetch("reason"), provider_response: response, provider_format: "responses")
      end

      def output_item(block)
        case block.fetch("type")
        when "text"
          { "type" => "message", "content" => [{ "type" => "output_text", "text" => block.fetch("text") }],
            "provider_payload" => block.compact }
        when "thinking"
          { "type" => "reasoning", "text" => (block["thinking"] unless block["redacted"]),
            "signature" => block["thinkingSignature"], "provider_payload" => block.compact }.compact
        when "toolCall"
          if block.key?("partial_json")
            raise ProviderStreamInterruptedError, "pi_messages ended before toolcall_end"
          end
          { "type" => "function_call", "id" => block.fetch("id"), "call_id" => block.fetch("id"),
            "name" => block.fetch("name"), "arguments" => JSON.generate(block.fetch("arguments").to_h),
            "provider_payload" => block.compact }
        else raise DecodeError, "unknown pi_messages content block #{block.fetch("type").inspect}"
        end
      end

      def normalize_usage(usage)
        usage = usage.to_h
        input = usage.fetch("input", 0).to_i + usage.fetch("cacheRead", 0).to_i + usage.fetch("cacheWrite", 0).to_i
        output = usage.fetch("output", 0).to_i
        { "input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output,
          "input_tokens_details" => { "cached_tokens" => usage.fetch("cacheRead", 0).to_i,
            "cache_creation_tokens" => usage.fetch("cacheWrite", 0).to_i } }
      end
    end
  end
end
