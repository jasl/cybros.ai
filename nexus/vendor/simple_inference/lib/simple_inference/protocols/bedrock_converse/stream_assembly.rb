module SimpleInference
  module Protocols
    class BedrockConverse
      # Mutable state belongs to one stream. Content indices are provider
      # positions, including reasoning that precedes text or tool calls.
      class StreamAssembly
        def initialize(emit)
          @emit = emit
          @content = {}
          @redacted_bytes = {}
          @usage = nil
          @stop_reason = nil
          @events_seen = 0
          @last_event = nil
        end

        def apply(name, event)
          @events_seen += 1
          @last_event = name
          case name
          when "contentBlockStart"
            @content[event.fetch("contentBlockIndex")] = event.fetch("start")
          when "contentBlockDelta"
            apply_delta(event)
          when "contentBlockStop"
            block = @content[event.fetch("contentBlockIndex")]
            if block && block["toolUse"]
              tool = block.fetch("toolUse")
              @emit.call(Responses::Events::ToolCallDone.new(item_id: tool.fetch("toolUseId"),
                call_id: tool.fetch("toolUseId"), name: tool.fetch("name"),
                arguments: tool.fetch("_input_json", "{}")))
            end
          when "messageStop"
            @stop_reason = event.fetch("stopReason")
          when "metadata"
            @usage = event["usage"]
          else
            nil
          end
        end

        def finish
          if @stop_reason.nil?
            raise ProviderStreamInterruptedError.new("Bedrock stream ended without messageStop",
              events_seen: @events_seen, last_event_type: @last_event)
          end
        end

        def body
          @redacted_bytes.each do |index, bytes|
            @content.fetch(index)["reasoningContent"] = { "redactedContent" => Base64.strict_encode64(bytes) }
          end
          { "output" => { "message" => { "role" => "assistant", "content" => @content.sort.map(&:last) } },
            "stopReason" => @stop_reason, "usage" => @usage }
        end

        private

        def apply_delta(event)
          index = event.fetch("contentBlockIndex")
          delta = event.fetch("delta")
          block = @content[index] ||= {}
          if delta.key?("text")
            text = delta.fetch("text")
            (block["text"] ||= +"") << text
            @emit.call(Responses::Events::TextDelta.new(delta: text))
          elsif delta.key?("toolUse")
            tool = block.fetch("toolUse")
            text = delta.fetch("toolUse").fetch("input")
            (tool["_input_json"] ||= +"") << text
            @emit.call(Responses::Events::ToolCallDelta.new(item_id: tool.fetch("toolUseId"),
              call_id: tool.fetch("toolUseId"), name: tool.fetch("name"), delta: text))
          elsif delta.key?("reasoningContent")
            apply_reasoning(block, delta.fetch("reasoningContent"), index)
          end
        end

        def apply_reasoning(block, delta, index)
          reasoning = block["reasoningContent"] ||= {}
          if delta.key?("redactedContent")
            # Each JSON delta encodes an independent byte slice. Concatenating
            # base64 strings corrupts padding; concatenate bytes and re-encode.
            (@redacted_bytes[index] ||= +"".b) << Base64.strict_decode64(delta.fetch("redactedContent"))
          else
            text = reasoning["reasoningText"] ||= { "text" => +"" }
            if delta.key?("text")
              text.fetch("text") << delta.fetch("text")
              @emit.call(Responses::Events::ReasoningDelta.new(delta: delta.fetch("text"), item_id: index.to_s))
            end
            if delta.key?("signature")
              (text["signature"] ||= +"") << delta.fetch("signature")
            end
          end
        rescue ArgumentError
          raise DecodeError, "invalid Bedrock reasoning bytes", cause: nil
        end
      end
    end
  end
end
