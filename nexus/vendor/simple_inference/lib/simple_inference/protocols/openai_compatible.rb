require "json"

require_relative "base"

module SimpleInference
  module Protocols
    # The chat-completions engine behind `OpenAICompatibleResponses` and
    # `OpenRouterResponses`: POST /chat/completions, buffered or as an SSE
    # stream. It carries no other endpoint, because every other workload has
    # its own protocol class that `ApiFormat` routes to.
    class OpenAICompatible < Base
      # POST /v1/chat/completions
      # params: { model: "model-name", messages: [...], ... }
      #
      # This is the internal chat engine: it keeps the **params intake, but the
      # body it builds exits through finalize_wire_body — the one seam where
      # protocol-built fields (deep-stringified) meet the caller's verbatim,
      # string-keyed extra_body wire fields.
      def chat_completions(extra_body: {}, **params)
        validate_extra_body(extra_body)

        post_json(api_path("/chat/completions"), finalize_wire_body(params, extra_body || {}))
      end

      # High-level helper for OpenAI-compatible chat.
      #
      # - Non-streaming: returns an OpenAI::ChatResult with `content` + `usage`.
      # - Streaming: yields delta strings to the block (if given), accumulates, and returns OpenAI::ChatResult.
      #
      # @param model [String]
      # @param messages [Array<Hash>]
      # @param stream [Boolean] force streaming when true (default: block_given?)
      # @param include_usage [Boolean, nil] when true (and streaming), requests usage in the final chunk
      # @param request_logprobs [Boolean] when true, requests logprobs (and collects them in streaming mode)
      # @param top_logprobs [Integer, nil] default: 5 (when request_logprobs is true)
      # @param params [Hash] additional OpenAI parameters (max_tokens, temperature, etc.)
      # @yield [String] delta content chunks (streaming only)
      # @return [SimpleInference::OpenAI::ChatResult]
      def chat(model:, messages:, stream: nil, include_usage: nil, request_logprobs: false, top_logprobs: 5, extra_body: {}, **params, &block)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?
        raise SimpleInference::ValidationError, "messages must be an Array" unless messages.is_a?(Array)

        use_stream = stream.nil? ? block_given? : stream

        request = { model: model, messages: messages }.merge(params)
        request.delete(:stream)

        if request_logprobs
          request[:logprobs] = true unless request.key?(:logprobs)
          if top_logprobs && !request.key?(:top_logprobs)
            request[:top_logprobs] = top_logprobs
          end
        end

        if use_stream && include_usage
          stream_options = request[:stream_options] || {}
          stream_options = stream_options.merge(include_usage: true) unless stream_options.key?(:include_usage)
          request[:stream_options] = stream_options
        end

        if use_stream
          full = +""
          reasoning_content = +""
          refusal = +""
          finish_reason = nil
          last_usage = nil
          collected_logprobs = []
          streamed_tool_calls = []
          events_seen = 0
          last_event_type = nil

          response =
            chat_completions_stream(extra_body: extra_body, **request) do |event|
              events_seen += 1
              last_event_type = event["object"].to_s
              delta = OpenAI.chat_completion_chunk_delta(event)
              if delta
                full << delta
                block.call(delta) if block
              end
              reasoning_delta = OpenAI.chat_completion_chunk_reasoning_delta(event)
              reasoning_content << reasoning_delta if reasoning_delta
              refusal_delta = OpenAI.chat_completion_chunk_refusal_delta(event)
              refusal << refusal_delta if refusal_delta

              fr = event.dig("choices", 0, "finish_reason")
              finish_reason = fr if fr

              if request_logprobs
                collected_logprobs.concat(Array(event.dig("choices", 0, "logprobs", "content")))
              end

              usage = OpenAI.chat_completion_usage(event)
              last_usage = usage if usage

              merge_stream_tool_calls(streamed_tool_calls, event)
            end

          response_usage = last_usage || OpenAI.chat_completion_usage(response)
          response_finish_reason = finish_reason || OpenAI.chat_completion_finish_reason(response)
          ensure_chat_stream_terminal(
            response, response_finish_reason,
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
          response = Response.new(
            status: response.status,
            headers: response.headers,
            body: response.body || synthesized_body,
            raw_body: response.raw_body
          )

          OpenAI::ChatResult.new(
            content: full,
            usage: response_usage,
            finish_reason: response_finish_reason,
            logprobs: collected_logprobs.empty? ? OpenAI.chat_completion_logprobs(response) : collected_logprobs,
            response: response
          )
        else
          response = chat_completions(extra_body: extra_body, **request)
          chat_result_from_response(response)
        end
      end

      # Streaming chat as an Enumerable.
      #
      # POST /v1/chat/completions (streaming)
      #
      # Yields parsed JSON events from an OpenAI-style SSE stream (`text/event-stream`).
      #
      # If no block is given, returns an Enumerator.
      #
      # Streaming support is a PROFILE capability fact, never a runtime
      # discovery: the old hidden second POST (triggered by matching an exact
      # "Streaming responses are not supported yet" error body) and the
      # synthesize-a-chunk ride-through for buffered JSON successes are both
      # deleted. A success response that did not stream is a typed error.
      def chat_completions_stream(extra_body: {}, **params)
        return enum_for(:chat_completions_stream, extra_body: extra_body, **params) unless block_given?

        validate_extra_body(extra_body)
        extra_body ||= {}

        # After the finalize seam the body has exactly one key type, so the
        # old symbol+string double-delete dance is a single forced write.
        body = finalize_wire_body(params, extra_body)
        body["stream"] = true

        response = post_json_stream(api_path("/chat/completions"), body) do |_event_name, event|
          raise_on_mid_stream_error_event(event)
          yield event
        end

        # Streaming success (incremental or buffered SSE) always carries
        # body: nil — the events were already yielded above.
        return response if response.success? && response.body.nil?

        if response.success?
          raise SimpleInference::ProviderStreamInterruptedError.new(
            "stream request returned a non-SSE success response (HTTP #{response.status}); " \
            "streaming support is a profile capability fact — refusing to synthesize a " \
            "stream from a buffered body",
            events_seen: 0,
            last_event_type: nil
          )
        end

        response
      end

      private

      def chat_result_from_response(response)
        OpenAI::ChatResult.new(
          content: OpenAI.chat_completion_content(response),
          usage: OpenAI.chat_completion_usage(response),
          finish_reason: OpenAI.chat_completion_finish_reason(response),
          logprobs: OpenAI.chat_completion_logprobs(response),
          response: response
        )
      end

      def base_url
        config.base_url
      end

      def api_path(endpoint)
        "#{config.api_prefix}#{endpoint}"
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

      # Some gateways (OpenRouter is the documented case) report mid-stream
      # failures as ordinary data events carrying a top-level error object
      # under HTTP 200. Riding through them silently produced truncated
      # results that looked complete; they are typed loud failures now.
      def raise_on_mid_stream_error_event(event)
        error = event["error"]
        return if error.nil?

        status = Integer(error["code"], exception: false) || 200
        message = error["message"].to_s
        message = "provider reported a mid-stream error event" if message.empty?

        raise SimpleInference::HTTPError.new(
          message,
          response: Response.new(
            status: status,
            headers: {},
            body: event,
            raw_body: JSON.generate(event),
          ),
        )
      end

      # The chat-completions terminal fact is the finish_reason chunk: a
      # provider-STARTED 2xx SSE stream that ended without one is an
      # INTERRUPTION — the SHARED cross-protocol typed error, never a silent
      # partial result. A Hash body means the response did not stream (the
      # buffered-JSON cases are handled by chat_completions_stream itself),
      # and non-2xx outcomes stay HTTP errors.
      def ensure_chat_stream_terminal(response, finish_reason, events_seen:, last_event_type:)
        return unless response.success? && response.body.nil?
        return unless finish_reason.nil? || finish_reason.to_s.empty?

        raise SimpleInference::ProviderStreamInterruptedError.new(
          "chat completions stream interrupted: ended before a terminal finish_reason chunk",
          events_seen: events_seen,
          last_event_type: last_event_type,
        )
      end

      def merge_stream_tool_calls(streamed_tool_calls, event)
        Array(event.dig("choices", 0, "delta", "tool_calls")).each_with_index do |entry, fallback_index|
          index = entry.fetch("index", fallback_index).to_i
          current = streamed_tool_calls[index] ||= {
            "type" => "function",
            "function" => { "arguments" => "" },
          }

          current["id"] = entry["id"] if entry["id"]
          current["type"] = entry["type"] if entry["type"]

          function = entry["function"]
          next if function.nil?

          current["function"]["name"] = function["name"] if function["name"]
          if function.key?("arguments")
            current["function"]["arguments"] = current["function"].fetch("arguments", "") + function["arguments"].to_s
          end
        end
      end

      # A streamed refusal folds into the message's own `refusal` field, where
      # a buffered answer carries it — never into `content`.
      def synthesize_stream_chat_completion_body(content:, finish_reason:, usage:, logprobs:, tool_calls:,
                                                 reasoning_content: nil, refusal: nil)
        message = {
          "role" => "assistant",
          "content" => content.to_s,
        }
        message["reasoning_content"] = reasoning_content.to_s unless reasoning_content.to_s.empty?
        message["refusal"] = refusal.to_s unless refusal.to_s.empty?
        compact_tool_calls = Array(tool_calls).compact
        message["tool_calls"] = compact_tool_calls if compact_tool_calls.any?

        choice = { "message" => message }
        choice["finish_reason"] = finish_reason if finish_reason
        choice["logprobs"] = { "content" => logprobs } if logprobs.is_a?(Array) && !logprobs.empty?

        body = { "choices" => [choice] }
        body["usage"] = stringify_usage(usage) if usage
        body
      end

      def stringify_usage(usage)
        case usage
        when Hash
          usage.each_with_object({}) do |(key, value), out|
            out[key.to_s] = stringify_usage(value)
          end
        when Array
          usage.map { |entry| stringify_usage(entry) }
        else
          usage
        end
      end

      def responses_messages_for(input, options)
        return responses_chat_messages_for(input, options) if input.is_a?(Array)

        messages = []
        instructions = options[:instructions]
        messages << { role: "system", content: instructions.to_s } unless instructions.to_s.strip.empty?
        messages << { role: "user", content: input }
        messages
      end

      def responses_chat_messages_for(input, options)
        messages = []
        instructions = options[:instructions]
        messages << { role: "system", content: instructions.to_s } unless instructions.to_s.strip.empty?

        Array(input).each_with_object(messages) do |entry, wire|
          next wire << { role: "user", content: entry } unless entry.is_a?(Hash)

          message = Internal::Keys.deep_stringify(entry)
          if message["type"].to_s == "function_call"
            fold_function_call(wire, message)
          else
            append_chat_message(wire, chat_wire_item(message) || chat_wire_message(message))
          end
        end
      end

      def chat_wire_message(message)
        message["content"] = responses_chat_content(message["content"]) if message.key?("content")
        message["tool_calls"] = chat_wire_tool_calls(message["tool_calls"]) if message["tool_calls"].is_a?(Array)
        message
      end

      # ONE ROUND, ONE ASSISTANT MESSAGE. A caller that splices a prior
      # round hands us its calls as N `function_call` ITEMS — the
      # Responses family's shape, one item per call. The chat wire says
      # the same round as ONE assistant message whose `tool_calls` carries
      # every call, so a call folds into the assistant message directly
      # before it: the previous call's, or the round's own words (and
      # whatever else that message carried, a reasoning echo say, rides
      # once). Lowered one message per call, a strict endpoint (Kimi K3 on
      # OpenRouter) refused the NEXT round — "tool messages need a
      # preceding assistant tool call" — and the loop halted on every
      # round of two or more calls. The other half: an assistant message
      # directly after the one carrying calls (words said between two
      # calls, or the fence a reasoning item thought there became) is the
      # same round's and folds into that message's content, so the next
      # call still folds there. A tool message never folds: it is the next
      # speaker, and a call or words after it open a new assistant message.
      def fold_function_call(wire, item)
        calls = chat_wire_tool_calls([item])
        return if calls.empty?

        previous = wire.last
        if previous.is_a?(Hash) && previous["role"] == "assistant"
          wire[-1] = previous.merge("tool_calls" => Array(previous["tool_calls"]) + calls)
        else
          wire << { "role" => "assistant", "content" => nil, "tool_calls" => calls }
        end
      end

      # The fold's second half (see fold_function_call): the lowered
      # message's content parts append to the calling message's, and any
      # calls it carried itself join the round's.
      def append_chat_message(wire, lowered)
        previous = wire.last
        calling = previous && previous["role"] == "assistant" && Array(previous["tool_calls"]).any?
        if calling && lowered["role"] == "assistant"
          wire[-1] = previous.merge(
            "content" => chat_content_parts(previous["content"]) + chat_content_parts(lowered["content"]),
            "tool_calls" => previous["tool_calls"] + Array(lowered["tool_calls"])
          )
        else
          wire << lowered
        end
      end

      # A merged content is one part list. The chat wire's content is its
      # own union — a part list, the string shorthand for one text part, or
      # absent (a calls-only message) — so each arm says what it adds.
      def chat_content_parts(content)
        case content
        in Array then content
        in String then [{ "type" => "text", "text" => content }]
        in nil then []
        else raise SimpleInference::ValidationError, "chat message content is a string or a part list, got #{content.class}"
        end
      end

      # THE RESPONSES-STYLE TOOL RESULT, lowered onto the chat wire. Every
      # Responses-shaped protocol translates the `function_call_output`
      # item; this one passed it through untouched, so it reached the wire
      # with NO `role` at all and the endpoint dropped or refused it — the
      # model called a tool, the result came back, and the model never saw
      # it. Returns nil for anything else, so an ordinary role message
      # takes chat_wire_message unchanged.
      def chat_wire_item(entry)
        return nil unless entry["type"].to_s == "function_call_output"

        id = (entry["call_id"] || entry["id"]).to_s
        return nil if id.empty?

        { "role" => "tool", "tool_call_id" => id,
          "content" => chat_wire_tool_output(entry["output"]) }
      end

      # The chat wire's tool message takes a STRING. A structured output
      # is serialized rather than dropped — the model reading it is the
      # only reason the round continues.
      def chat_wire_tool_output(output)
        case output
        when nil then ""
        when String then output
        else JSON.generate(output)
        end
      end

      # The kernel splices prior-round tool calls in its canonical flat shape
      # ({"id","name","arguments"}); the chat-completions wire requires the
      # nested function envelope with a "type" tag (DeepSeek's strict parser
      # 400s without it — "missing field `type`"). Accept flat, Responses-item
      # ("call_id"), or already-nested entries.
      def chat_wire_tool_calls(tool_calls)
        tool_calls.filter_map do |entry|
          function = entry["function"] || entry
          name = function["name"].to_s
          next if name.empty?

          {
            "id" => (entry["id"] || entry["call_id"]).to_s,
            "type" => "function",
            "function" => { "name" => name, "arguments" => tool_call_arguments_string(function["arguments"] || entry["arguments"]) },
          }
        end
      end

      def tool_call_arguments_string(arguments)
        return "{}" if arguments.nil?
        return arguments if arguments.is_a?(String)

        JSON.generate(arguments)
      end

      def responses_chat_content(content)
        case content
        when Array
          content.map { |part| responses_chat_content_part(part) }
        when Hash
          [responses_chat_content_part(content)]
        else
          content
        end
      end

      # A scalar part is the caller's shorthand for a text part — normalized
      # once here, at the lowering boundary.
      def responses_chat_content_part(part)
        return { "type" => "text", "text" => part.to_s } unless part.is_a?(Hash)

        normalized = Internal::Keys.deep_stringify(part)
        type = normalized["type"].to_s

        case type
        when "input_text", "output_text"
          { "type" => "text", "text" => normalized["text"].to_s }
        when "input_image", "image", "image_url"
          {
            "type" => "image_url",
            "image_url" => {
              "url" => chat_image_data_url(normalized),
            },
          }
        else
          normalized
        end
      end

      # Media ingress is BYTES-ONLY (transport policy, register Input-media
      # profiles v1): a chat-family image part carries a
      # SimpleInference::MediaInput and the lane CONSTRUCTS the base64 data
      # URL from those verified bytes here. Caller-supplied http(s) URLs,
      # data URIs, host paths, and provider file ids are loud rejections at
      # this lowering — never forwarded, even though the chat-completions
      # wire would accept a remote image_url.
      def chat_image_data_url(part)
        # The caller's image_url is a MediaInput or the {"url" => MediaInput}
        # envelope — the wire's own two spellings, split once here.
        media = part["image_url"]
        media = media["url"] if media.is_a?(Hash) && media.key?("url")
        unless media.is_a?(SimpleInference::MediaInput)
          raise SimpleInference::ValidationError,
                "chat-family image parts carry raw bytes via SimpleInference::MediaInput — " \
                "caller http(s) URLs, data URIs, host paths, and provider file handles are " \
                "rejected at this lane's lowering (got #{media.class})"
        end

        "data:#{media.media_type};base64,#{[media.bytes].pack("m0")}"
      end

      def emit_stream_tool_call_events(emit:, event:, streamed_tool_calls:, emitted_done:)
        Array(event.dig("choices", 0, "delta", "tool_calls")).each_with_index do |entry, fallback_index|
          index = entry.fetch("index", fallback_index).to_i
          current = streamed_tool_calls[index] || {}
          function = current["function"] || {}
          item_id = current["id"] || entry["id"] || "tool_call_#{index}"

          emit.call(
            SimpleInference::Responses::Events::ToolCallDelta.new(
              item_id: item_id,
              call_id: current["id"] || entry["id"],
              name: function["name"],
              delta: entry.dig("function", "arguments").to_s
            )
          )
        end

        return unless event.dig("choices", 0, "finish_reason").to_s == "tool_calls"

        emit_remaining_stream_tool_call_done_events(
          emit: emit,
          streamed_tool_calls: streamed_tool_calls,
          emitted_done: emitted_done
        )
      end

      def emit_remaining_stream_tool_call_done_events(emit:, streamed_tool_calls:, emitted_done:)
        streamed_tool_calls.each_with_index do |entry, index|
          next if entry.nil?

          item_id = entry["id"] || "tool_call_#{index}"
          next if emitted_done[item_id]

          function = entry["function"] || {}
          emit.call(
            SimpleInference::Responses::Events::ToolCallDone.new(
              item_id: item_id,
              call_id: entry["id"],
              name: function["name"],
              arguments: function["arguments"].to_s
            )
          )
          emitted_done[item_id] = true
        end
      end
    end
  end
end
