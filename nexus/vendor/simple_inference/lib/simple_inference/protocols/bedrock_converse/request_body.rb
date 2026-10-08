module SimpleInference
  module Protocols
    class BedrockConverse
      module RequestBody
        private

        def build_request_body(input, options)
          system = content_blocks(Internal::Keys.deep_stringify_entry(options[:instructions]))
          messages = []
          entries = case input
          when Array then input
          when String then [{ "role" => "user", "content" => input }]
          else
                      raise ValidationError, "Bedrock input must be text or a message array"
          end
          entries.each do |entry|
            entry = case entry
            when String then { "role" => "user", "content" => entry }
            when Hash then Internal::Keys.deep_stringify(entry)
            else
                      raise ValidationError, "Bedrock messages must be objects or text"
            end
            if entry["role"] == "system" && messages.empty?
              system.concat(content_blocks(entry["content"]))
            else
              role, blocks = message_blocks(entry)
              append_message(messages, role, blocks)
            end
          end
          body = { "messages" => messages }
          body["system"] = system unless system.empty?
          inference = { "maxTokens" => options[:max_output_tokens], "temperature" => options[:temperature],
                        "topP" => options[:top_p], "stopSequences" => options[:stop] }.compact
          fields = thinking_fields(options)
          if @thinking_omits_temperature && fields.dig("thinking", "type") != "disabled" && fields["thinking"]
            inference.delete("temperature")
          end
          body["inferenceConfig"] = inference unless inference.empty?
          body["additionalModelRequestFields"] = fields unless fields.empty?
          config = tool_config(options[:tools], options[:tool_choice])
          body["toolConfig"] = config if config
          body
        end

        def message_blocks(entry)
          case entry["type"]
          when "function_call"
            ["assistant", [tool_call_block(entry)]]
          when "function_call_output"
            ["user", cached_blocks(tool_result_block(entry, entry["output"]), entry)]
          else
            role = entry.fetch("role", "user")
            unless ACCEPTED_ROLES.include?(role)
              raise ValidationError, "unsupported message role #{role.inspect} for Bedrock Converse"
            end
            if role == "tool"
              ["user", cached_blocks(tool_result_block(entry, entry["content"]), entry)]
            else
              # Only leading system text can enter the top-level system field.
              # Later instructions retain their history position and prefix.
              role = "user" if %w[system developer].include?(role)
              blocks = content_blocks(entry["content"])
              blocks.concat(Array(entry["tool_calls"]).map { |call| tool_call_block(call) })
              [role, blocks]
            end
          end
        end

        def append_message(messages, role, blocks)
          return if blocks.empty?

          if messages.last && messages.last.fetch("role") == role
            messages.last.fetch("content").concat(blocks)
          else
            messages << { "role" => role, "content" => blocks }
          end
        end

        def content_blocks(content)
          case content
          when nil then []
          when String then content.empty? ? [] : [{ "text" => content }]
          when Array then content.flat_map { |part| content_blocks(part) }
          when Hash then content_part(content)
          else
            raise ValidationError, "Bedrock content must be text or content parts"
          end
        end

        def content_part(part)
          block = case part.fetch("type", "text")
          when "text", "input_text", "output_text"
                    { "text" => part.fetch("text").to_s }
          when "input_image", "image", "image_url"
                    image_block(part)
          when "input_file"
                    media = input_file_media(part)
                    { "document" => { "format" => "pdf", "name" => "Document",
                                      "source" => { "bytes" => Base64.strict_encode64(media.bytes) } } }
          when "bedrock_reasoning"
                    part.fetch("provider_payload")
          else
                    raise ValidationError, "unsupported Bedrock content part #{part["type"].inspect}"
          end
          cached_blocks(block, part)
        end

        def cached_blocks(block, source)
          cache = source["cache_control"]
          if cache
            point = { "type" => "default" }
            point["ttl"] = cache.fetch("ttl") if cache["ttl"]
            [block, { "cachePoint" => point }]
          else
            [block]
          end
        end

        def image_block(part)
          carrier = part["image_url"] || part["url"] || part["source"]
          media = case carrier
          when Hash then carrier["url"] || carrier["data"]
          else carrier
          end
          unless media in MediaInput
            raise ValidationError, "Bedrock image content requires raw bytes via SimpleInference::MediaInput"
          end
          format = { "image/jpeg" => "jpeg", "image/png" => "png", "image/gif" => "gif", "image/webp" => "webp" }[media.media_type]
          raise ValidationError, "unsupported Bedrock image media type" unless format

          { "image" => { "format" => format, "source" => { "bytes" => Base64.strict_encode64(media.bytes) } } }
        end

        def tool_call_block(entry)
          function = entry["function"] || entry
          { "toolUse" => { "toolUseId" => tool_id(entry["call_id"] || entry["id"]),
                           "name" => function.fetch("name"), "input" => tool_arguments(function["arguments"]) } }
        end

        def tool_id(id)
          id.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")[0, 64]
        end

        def tool_arguments(arguments)
          case arguments
          when Hash then arguments
          when nil, "" then {}
          else JSON.parse(arguments.to_s)
          end
        rescue JSON::ParserError
          # A cut call still replays beside its error result; it never reruns.
          {}
        end

        def tool_result_block(entry, output)
          content = case output
          when Array then content_blocks(output)
          when Hash then [{ "text" => JSON.generate(output) }]
          else
            text = output.to_s
            [{ "text" => text.empty? ? "<empty>" : text }]
          end
          content = [{ "text" => "<empty>" }] if content.empty?
          { "toolResult" => { "toolUseId" => tool_id(entry["call_id"] || entry["tool_call_id"]),
                              "content" => content,
                              "status" => entry["is_error"] ? "error" : "success" } }
        end

        def tool_config(tools, choice)
          return if choice == "none" || tools.nil? || tools.empty?

          config = { "tools" => tools.map do |tool|
            tool = Internal::Keys.deep_stringify(tool)
            unless tool.fetch("type", "function") == "function"
              raise ValidationError, "Bedrock Converse accepts function tools"
            end
            function = tool["function"] || tool
            { "toolSpec" => { "name" => function.fetch("name"), "description" => function["description"],
                              "inputSchema" => { "json" => function.fetch("parameters", { "type" => "object", "properties" => {} }) },
                              "strict" => function["strict"] }.compact }
          end }
          if choice
            config["toolChoice"] = case choice
            when "auto" then { "auto" => {} }
            when "required", "any" then { "any" => {} }
            when Hash
                                     function = Internal::Keys.deep_stringify(choice)
                                     { "tool" => { "name" => function.dig("function", "name") || function.fetch("name") } }
            else
                                     raise ValidationError, "unsupported Bedrock tool choice"
            end
          end
          config
        end

        def thinking_fields(options)
          enabled = validated_reasoning_enabled(options[:reasoning_enabled], effort: options[:reasoning_effort])
          effort = options[:reasoning_effort]&.to_s unless enabled == false
          if effort && !REASONING_EFFORTS.include?(effort)
            raise ValidationError, "unsupported Bedrock reasoning effort #{effort.inspect}"
          end
          enabled = false if effort == "none"
          effort = @reasoning_effort_map.fetch(effort, effort) if effort
          if options[:thinking] && enabled != false
            return { "thinking" => Internal::Keys.deep_stringify(options[:thinking]) }
          end
          return {} if enabled.nil? && effort.nil?

          case @bedrock_thinking_control
          when "adaptive", "budget"
            return { "thinking" => { "type" => "disabled" } } if enabled == false

            if @bedrock_thinking_control == "adaptive"
              thinking_options({ "type" => "adaptive" }).merge(
                "output_config" => (effort ? { "effort" => effort } : nil)
              ).compact
            else
              budget = @thinking_budgets.fetch(effort || "minimal")
              maximum = options[:max_output_tokens]
              budget = [budget, maximum - 1024].min if maximum
              if budget < 1024
                raise ValidationError, "Bedrock thinking requires at least 1024 thinking tokens and 1024 answer tokens"
              end
              thinking_options({ "type" => "enabled", "budget_tokens" => budget },
                betas: ["interleaved-thinking-2025-05-14"])
            end
          when "reasoning_effort"
            enabled == false || effort.nil? ? {} : { "reasoning_effort" => effort }
          when "nested_effort"
            enabled == false || effort.nil? ? {} : { "reasoning" => { "effort" => effort } }
          else
            {}
          end
        end

        def thinking_options(thinking, betas: [])
          thinking["display"] = "summarized" unless @bedrock_omit_thinking_display
          if @thinking_binding
            thinking["block_binding"] = { "prefix_mismatch_behavior" => @thinking_binding }
            betas = betas + ["thinking-binding-controls-2026-08-01"]
          end
          fields = { "thinking" => thinking }
          fields["anthropic_beta"] = betas unless betas.empty?
          fields
        end
      end
    end
  end
end
