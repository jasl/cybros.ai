require_relative "openai_compatible_responses"
require "digest"

module SimpleInference
  module Protocols
    # Mistral's Chat wire embeds thinking blocks in content, including on
    # replay. Normalize only at that wire boundary; keep the shared stream
    # lifecycle, tool assembly and usage handling.
    class MistralChat < OpenAICompatibleResponses
      def self.protocol_option_keys = superclass.protocol_option_keys

      def initialize(stream_include_usage: false, **connection)
        super(stream_include_usage: stream_include_usage, **connection)
      end

      private

      def coerce_messages(input, options)
        messages = normalize_tool_ids(super)
        messages.map do |message|
          next message unless message["role"] == "assistant"

          message = message.merge("prefix" => false)
          thinking = message.delete("reasoning_content")
          next message if thinking.to_s.empty?

          content = message["content"]
          parts = Array.try_convert(content) || [{ type: "text", text: content.to_s }]
          message.merge("content" => [{ type: "thinking", thinking: [{ type: "text", text: thinking }] }] + parts)
        end
      end

      def normalize_tool_ids(messages)
        ids, owners = {}, {}
        normalize = lambda do |original|
          ids.fetch(original) do
            stripped = original.gsub(/[^a-zA-Z0-9]/, "")
            candidate = stripped.length == 9 ? stripped : Digest::SHA256.hexdigest(original)[0, 9]
            attempt = 0
            while owners.key?(candidate)
              attempt += 1
              candidate = Digest::SHA256.hexdigest("#{original}:#{attempt}")[0, 9]
            end
            owners[candidate] = original
            ids[original] = candidate
          end
        end
        messages.map do |message|
          if message["tool_call_id"]
            message = message.merge("tool_call_id" => normalize.call(message.fetch("tool_call_id")))
          end
          if message["tool_calls"]
            calls = message.fetch("tool_calls").map { |call| call.merge("id" => normalize.call(call.fetch("id"))) }
            message = message.merge("tool_calls" => calls)
          end
          message
        end
      end

      def normalize_chat_event(event)
        normalize_body(event, "delta")
      end

      def normalize_chat_response(response)
        Response.new(
          status: response.status, headers: response.headers,
          body: normalize_body(response.body, "message"), raw_body: response.raw_body,
        )
      end

      def normalize_body(body, field)
        body = body.to_h
        choices = Array(body["choices"]).map do |choice|
          message = choice[field]
          next choice unless message
          parts = Array.try_convert(message["content"])
          next choice unless parts

          text = parts.filter_map { |part| part["text"] if part["type"] == "text" }.join
          thinking = parts.select { |part| part["type"] == "thinking" }
            .flat_map { |part| Array(part["thinking"]) }.map { |part| part.fetch("text", "") }.join
          choice.merge(field => message.merge("content" => text, "reasoning_content" => thinking))
        end
        body.merge("choices" => choices)
      end
    end
  end
end
