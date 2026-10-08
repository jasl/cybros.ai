require "aws-eventstream"
require "base64"
require_relative "base"

module SimpleInference
  module Protocols
    # Bedrock's native Converse JSON requests and AWS binary EventStream.
    # Authentication remains the connection's explicit bearer header; this
    # protocol does not discover AWS credentials or sign requests with SigV4.
    class BedrockConverse < Base
      require_relative "bedrock_converse/request_body"
      require_relative "bedrock_converse/stream_assembly"

      include RequestBody

      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze
      THINKING_CONTROLS = %w[none adaptive budget reasoning_effort nested_effort].freeze
      REASONING_EFFORTS = %w[none minimal low medium high xhigh max].freeze
      THINKING_BUDGETS = { "minimal" => 1024, "low" => 2048, "medium" => 8192,
                          "high" => 16_384, "xhigh" => 16_384, "max" => 16_384 }.freeze
      EVENTSTREAM_ERRORS = [
        Aws::EventStream::Errors::PreludeChecksumError,
        Aws::EventStream::Errors::MessageChecksumError,
        Aws::EventStream::Errors::IncompleteMessageError,
        Aws::EventStream::Errors::ReadBytesExceedLengthError,
        Aws::EventStream::Errors::EventPayloadLengthExceedError,
        Aws::EventStream::Errors::EventHeadersLengthExceedError,
      ].freeze

      def self.request_option_keys
        %i[max_output_tokens temperature top_p stop instructions tools tool_choice
           reasoning_enabled reasoning_effort thinking].freeze
      end

      def initialize(bedrock_thinking_control: "none", thinking_budgets: nil,
                     reasoning_effort_map: nil, thinking_omits_temperature: false,
                     bedrock_omit_thinking_display: false, thinking_binding: nil, **connection)
        super(**connection)
        unless THINKING_CONTROLS.include?(bedrock_thinking_control)
          raise ConfigurationError, "bedrock_thinking_control must be one of #{THINKING_CONTROLS.join(", ")}"
        end
        @bedrock_thinking_control = bedrock_thinking_control
        @thinking_budgets = THINKING_BUDGETS.merge(thinking_budgets.to_h.transform_keys(&:to_s)).freeze
        @reasoning_effort_map = reasoning_effort_map.to_h.transform_keys(&:to_s).freeze
        @thinking_omits_temperature = thinking_omits_temperature == true
        @bedrock_omit_thinking_display = bedrock_omit_thinking_display == true
        unless thinking_binding.nil? || %w[drop_block error].include?(thinking_binding)
          raise ConfigurationError, "thinking_binding must be drop_block or error"
        end
        @thinking_binding = thinking_binding
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        path, body = converse_request(model, input, options, stream: false)
        compile_json_request(path: path, body: body, stream: false) do |connection, compiled|
          result_from_response(compiled_response(compiled, config: connection))
        end
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def compile_stream(model:, input:, **options)
        path, body = converse_request(model, input, options, stream: true)
        validate_url("#{config.base_url}#{path}")
        CompiledRequest.new(http_method: :post, path: path,
          headers: { "Content-Type" => "application/json", "Accept" => "application/vnd.amazon.eventstream" },
          payload: serialize_json_body(body), stream: true, expect_json: false) do |connection, compiled|
          Responses::Stream.new do |&emit|
            assembly = StreamAssembly.new(emit)
            response = event_stream_response(compiled, connection) do |name, event|
              assembly.apply(name, event)
            end
            assembly.finish unless response.body
            response = response.with(body: assembly.body) unless response.body
            result = result_from_response(response)
            emit.call(Responses::Events::Completed.new(result: result))
            result
          end
        end
      end

      private

      def converse_request(model, input, options, stream:)
        model = model.to_s
        raise ValidationError, "model is required" if model.strip.empty?

        declared, extra_body = split_request_options(options)
        body = finalize_wire_body(build_request_body(input, declared), extra_body)
        ["/model/#{URI.encode_uri_component(model)}/#{stream ? "converse-stream" : "converse"}", body]
      end

      def compiled_connection_headers(connection)
        connection.authentication_headers(default: "bearer")
      end

      def event_stream_response(compiled, connection)
        env = compiled_request_env(compiled, connection)
        validate_url(env.fetch(:url))
        decoder = Aws::EventStream::Decoder.new
        streamed = false
        consume = lambda do |chunk|
          streamed = true
          message, = decoder.decode_chunk(chunk)
          # Each iteration removes one complete frame from this finite chunk.
          while message
            name, event = decode_event(message)
            yield name, event
            message, = decoder.decode_chunk
          end
        end
        envelope = Internal::Envelope.from_h(connection.adapter.call_stream(env, &consume))
        if envelope.event_stream?
          consume.call(envelope.body.to_s) unless streamed
          Response.new(status: envelope.status, headers: envelope.headers, body: nil, raw_body: "")
        else
          response = json_response(envelope, parse: true)
          maybe_raise_http_error(response: response, raise_on_http_error: connection.raise_on_error)
          response
        end
      rescue *EVENTSTREAM_ERRORS
        raise DecodeError, "invalid Bedrock event stream frame", cause: nil
      rescue Timeout::Error => error
        raise TimeoutError, error.message
      rescue SocketError, SystemCallError => error
        raise ConnectionError, error.message
      end

      def decode_event(message)
        begin
          event = parse_json_object(message.payload.read)
          kind = message.headers.fetch(":message-type").value
          name = message.headers[kind == "exception" ? ":exception-type" : ":event-type"]&.value
          if kind == "exception" || kind == "error"
            raise Error, "Bedrock stream reported #{name || message.headers[":error-code"]&.value || "an error"}"
          end
          [name, event]
        ensure
          message.payload.close
        end
      end

      def result_from_response(response)
        body = response.body || {}
        content = body.dig("output", "message", "content") || []
        items = content.map { |block| output_item(block) }.compact
        detail = body["stopReason"]
        Responses::Result.new(
          id: response.headers["x-amzn-requestid"],
          output_text: content.filter_map { |block| block["text"] }.join,
          output_items: items, tool_calls: Responses::Result.tool_calls_from_output_items(items),
          usage: normalize_usage(body["usage"]), finish_reason: detail, finish_detail: detail,
          refusal: Responses::Refusal.for_finish(FinishQuality::BEDROCK, detail),
          provider_response: response, provider_format: "responses"
        )
      end

      def output_item(block)
        if block.key?("text")
          { "type" => "message", "content" => [{ "type" => "output_text", "text" => block.fetch("text") }] }
        elsif block.key?("toolUse")
          tool = block.fetch("toolUse")
          { "type" => "function_call", "id" => tool.fetch("toolUseId"), "call_id" => tool.fetch("toolUseId"),
            "name" => tool.fetch("name"), "arguments" => tool["_input_json"] || JSON.generate(tool.fetch("input", {})) }
        elsif block.key?("reasoningContent")
          reasoning = block.fetch("reasoningContent")
          if reasoning.key?("redactedContent")
            { "type" => "redacted_thinking", "data" => reasoning.fetch("redactedContent"), "provider_payload" => block }
          else
            text = reasoning.fetch("reasoningText")
            { "type" => "reasoning", "text" => text.fetch("text", ""),
              "signature" => text["signature"], "provider_payload" => block }.compact
          end
        end
      end

      def normalize_usage(usage)
        return if usage.nil?

        normalized = { "input_tokens" => usage["inputTokens"], "output_tokens" => usage["outputTokens"],
          "total_tokens" => usage["totalTokens"], "cache_read_input_tokens" => usage["cacheReadInputTokens"],
          "cache_creation_input_tokens" => usage["cacheWriteInputTokens"] }.compact
        # AWS reports one write breakdown per TTL, beside the total write
        # count. Preserve the values for the consumer's accounting boundary.
        details = usage.fetch("cacheDetails", []).each_with_object({}) do |detail, counts|
          key = { "1h" => "ephemeral_1h_input_tokens", "5m" => "ephemeral_5m_input_tokens" }[detail.fetch("ttl")]
          counts[key] = detail.fetch("inputTokens") if key
        end
        normalized["cache_creation"] = details unless details.empty?
        normalized
      end
    end
  end
end
