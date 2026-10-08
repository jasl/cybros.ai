module SimpleInference
  module Protocols
    class PiMessages
      module RequestBody
        private

        def build_request_body(model:, input:, options:)
          messages = transcript_messages(input, model: model)
          instructions = options[:instructions].to_s
          tools = Array(options[:tools]).map { |tool| transcript_tool(tool.to_h) }
          unless instructions.empty? && tools.empty?
            system = { "role" => "system", "content" => instructions, "timestamp" => 0 }
            system["toolsAdded"] = tools unless tools.empty?
            messages.unshift(system)
          end
          enabled = validated_reasoning_enabled(options[:reasoning_enabled], effort: options[:reasoning_effort])
          effort = enabled == false ? nil : options[:reasoning_effort]&.to_s
          if effort && !REASONING_EFFORTS.include?(effort)
            raise ValidationError, "pi_messages reasoning_effort must be #{REASONING_EFFORTS.join("|")}"
          end
          # Pi omits reasoning when disabled; its backend chooses the model
          # default when neither an effort nor a disable was supplied.
          selected = {
            temperature: options[:temperature], maxTokens: options[:max_output_tokens],
            reasoning: (effort unless effort == "none"), cacheRetention: options[:cache_retention],
            sessionId: options[:session_id], toolChoice: tool_choice(options[:tool_choice]),
          }.compact
          { model: model, context: { messages: messages }, options: selected }
        end

        def transcript_messages(input, model:)
          entries = case input
          when String then [{ "role" => "user", "content" => input }]
          when Array then input
          else raise ValidationError, "pi_messages input must be text or a message array"
          end
          names = {}
          entries.each_with_object([]) do |entry, messages|
            entry = case entry
            when String then { "role" => "user", "content" => entry }
            when Hash then Internal::Keys.shallow_stringify(entry)
            else raise ValidationError, "pi_messages entries must be text or message objects"
            end
            case entry["type"]
            when "function_call"
              block = tool_call(entry)
              names[block.fetch("id")] = block.fetch("name")
              append_assistant(messages, [block], model: model)
            when "function_call_output"
              id = entry.fetch("call_id")
              name = entry["name"] || names.fetch(id) { raise ValidationError, "tool result is missing its name" }
              messages << tool_result(id, name, entry["output"], error: entry["is_error"] == true)
            else
              role = entry.fetch("role", "user").to_s
              raise ValidationError, "unsupported pi_messages role #{role.inspect}" unless ACCEPTED_ROLES.include?(role)

              role = "system" if role == "developer"
              if role == "tool"
                id = entry["tool_call_id"] || entry.fetch("call_id")
                name = entry["name"] || names.fetch(id) { raise ValidationError, "tool result is missing its name" }
                messages << tool_result(id, name, entry["content"], error: entry["is_error"] == true)
              elsif role == "assistant"
                calls = Array(entry["tool_calls"]).map { |call| tool_call(Internal::Keys.shallow_stringify(call)) }
                calls.each { |call| names[call.fetch("id")] = call.fetch("name") }
                append_assistant(messages, content_parts(entry["content"]) + calls, model: model)
              else
                messages << { "role" => role, "content" => content_parts(entry["content"]), "timestamp" => 0 }
              end
            end
          end
        end

        def append_assistant(messages, parts, model:)
          if messages.last&.fetch("role") == "assistant"
            messages.last.fetch("content").concat(parts)
          else
            messages << { "role" => "assistant", "content" => parts, "api" => "pi-messages",
              "provider" => @provider_id, "model" => model, "usage" => empty_usage,
              "stopReason" => "stop", "timestamp" => 0 }
          end
        end

        def empty_usage
          { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0, "totalTokens" => 0,
            "cost" => { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0, "total" => 0 } }
        end

        def tool_result(id, name, content, error:)
          { "role" => "toolResult", "toolCallId" => id, "toolName" => name,
            "content" => content_parts(content), "isError" => error, "timestamp" => 0 }
        end

        def content_parts(content)
          parts = case content
          when nil then []
          when String then [{ "type" => "text", "text" => content }]
          when Array then content
          else raise ValidationError, "pi_messages content must be text or a part array"
          end
          parts.map do |part|
            part = Internal::Keys.shallow_stringify(part.to_h)
            case part.fetch("type")
            when "text", "input_text", "output_text" then { "type" => "text", "text" => part.fetch("text").to_s }
            when "thinking" then part.slice("type", "thinking", "thinkingSignature", "redacted")
            when "input_image", "image", "image_url"
              carrier = part["image_url"] || part["url"] || part["source"]
              media = case carrier
              when MediaInput then carrier
              when Hash then carrier.fetch("url")
              else raise ValidationError, "pi_messages images require prepared MediaInput bytes"
              end
              { "type" => "image", "data" => [media.bytes].pack("m0"), "mimeType" => media.media_type }
            else raise ValidationError, "unsupported pi_messages content part #{part.fetch("type").inspect}"
            end
          end
        end

        def tool_call(entry)
          function = Internal::Keys.shallow_stringify(entry.fetch("function", entry))
          { "type" => "toolCall", "id" => entry["call_id"] || entry.fetch("id"),
            "name" => function.fetch("name"), "arguments" => tool_arguments(function.fetch("arguments", {})) }
        end

        def tool_arguments(arguments)
          case arguments
          when String then JSON.parse(arguments).to_h
          when Hash then arguments
          else raise ValidationError, "tool arguments must be an object or JSON object string"
          end
        rescue JSON::ParserError
          # A cut call replays beside its error result; it is never executed.
          {}
        end

        def transcript_tool(tool)
          tool = Internal::Keys.shallow_stringify(tool)
          function = Internal::Keys.shallow_stringify(tool.fetch("function", tool))
          { "name" => function.fetch("name"), "description" => function.fetch("description", ""),
            "parameters" => function.fetch("parameters", { "type" => "object", "properties" => {} }) }
        end

        def tool_choice(choice)
          case choice
          when nil then nil
          when String, Symbol
            value = choice.to_s
            raise ValidationError, "pi_messages tool_choice must be auto, none or required" unless %w[auto none required].include?(value)

            value
          when Hash
            choice = Internal::Keys.shallow_stringify(choice)
            function = Internal::Keys.shallow_stringify(choice.fetch("function", choice))
            { type: "function", function: { name: function.fetch("name") } }
          else raise ValidationError, "invalid pi_messages tool_choice"
          end
        end
      end
    end
  end
end
