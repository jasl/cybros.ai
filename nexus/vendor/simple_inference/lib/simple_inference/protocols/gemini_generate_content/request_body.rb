module SimpleInference
  module Protocols
    class GeminiGenerateContent
      # Canonical request inputs and options lowered into this protocol's body.
      module RequestBody
        private

        def build_request_body(input:, declared:)
          system_instruction, contents = coerce_contents(input, declared)

          body = {
            contents: contents,
          }

          if system_instruction && !system_instruction.empty?
            body[:systemInstruction] = {
              parts: [
                { text: system_instruction },
              ],
            }
          end

          tools = normalize_tools(declared[:tools])
          body[:tools] = tools if tools.any?
          tool_config = build_tool_config(declared[:tool_choice])
          body[:toolConfig] = tool_config if tool_config

          generation_config = {}
          generation_config[:maxOutputTokens] = declared[:max_output_tokens] if declared.key?(:max_output_tokens)
          # temperature/top_p/top_k/n never reach this builder — they are
          # register-frozen local rejections (reject_locally_rejected_options),
          # and no candidateCount surface exists on this lane.
          # seed / response_format live INSIDE generationConfig; as top-level
          # fields Google's generateContent rejects them with a 400.
          generation_config[:seed] = declared[:seed] if declared.key?(:seed)
          apply_response_format(generation_config, declared[:response_format])
          thinking_config = gemini_thinking_config(declared)
          generation_config[:thinkingConfig] = thinking_config if thinking_config
          body[:generationConfig] = generation_config unless generation_config.empty?

          body
        end

        # OpenAI-shaped response_format -> Gemini structured output:
        # json_object => responseMimeType application/json; json_schema
        # additionally carries the raw JSON Schema via responseJsonSchema
        # (Gemini's native JSON-Schema field). "text"/unknown types add nothing.
        def apply_response_format(generation_config, response_format)
          return if response_format.nil?

          format = Internal::Keys.shallow_symbolize(response_format)
          case format[:type].to_s
          when "json_object"
            generation_config[:responseMimeType] = "application/json"
          when "json_schema"
            generation_config[:responseMimeType] = "application/json"
            schema = format[:schema]
            generation_config[:responseJsonSchema] = schema if schema
          else
            nil
          end
        end

        # The catalog explicitly selects level or budget; neither model names
        # nor provider names select wire behavior here. The existing level
        # lane keeps its no-disable contract; older models declare budgets.
        def gemini_thinking_config(declared)
          enabled = validated_reasoning_enabled(declared[:reasoning_enabled], effort: declared[:reasoning_effort])
          return gemini_thinking_budget(declared, enabled) if @thinking_control == "budget"
          if enabled == false
            raise SimpleInference::ValidationError, "gemini_generate_content cannot disable thinking on this wire"
          end

          existing = declared[:thinking_config]
          return Internal::Keys.shallow_symbolize(existing) unless existing.nil?

          effort = declared[:reasoning_effort]
          return nil if effort.nil?

          level = effort.to_s
          unless THINKING_LEVELS.include?(level)
            raise SimpleInference::ValidationError,
                  "reasoning_effort #{effort.inspect} is outside the frozen gemini 3.x thinkingLevel " \
                  "vocabulary (#{THINKING_LEVELS.join("|")}) — there is no disable level and no " \
                  "nearest-level mapping on this lane"
          end

          {
            includeThoughts: true,
            thinkingLevel: level,
          }
        end

        def gemini_thinking_budget(declared, enabled)
          return { thinkingBudget: 0 } if enabled == false
          existing = declared[:thinking_config]
          return Internal::Keys.shallow_symbolize(existing) unless existing.nil?

          effort = declared[:reasoning_effort]&.to_s
          return nil if effort.nil? && enabled.nil?
          budget = effort.nil? ? -1 : @thinking_budgets.fetch(effort) do
            raise SimpleInference::ValidationError, "thinking budget is not declared for effort #{effort.inspect}"
          end
          { includeThoughts: true, thinkingBudget: budget }
        end

        # The caller's input enters here once: a String, or an Array whose
        # entries are message Hashes or bare user strings.
        def coerce_contents(input, declared)
          entries = input.is_a?(Array) ? input : [{ role: "user", content: input }]
          entries = entries.map { |entry| entry.is_a?(Hash) ? Internal::Keys.shallow_stringify(entry) : { "role" => "user", "content" => entry } }

          system_segments = []
          instructions = declared[:instructions]
          system_segments << instructions.to_s unless instructions.to_s.strip.empty?

          contents = []
          function_names = {}

          entries.each do |entry|
            if entry["role"].to_s == "system"
              text = stringify_content(entry["content"])
              system_segments << text unless text.empty?
              next
            end

            append_entry(contents, entry, function_names)
          end

          system_instruction = system_segments.join("\n\n").strip
          system_instruction = nil if system_instruction.empty?

          reject_assistant_last_input(contents)

          [system_instruction, contents]
        end

        # Register-frozen disposition: input whose last nonempty turn is
        # assistant (wire "model") is rejected pre-wire — never dropped,
        # relabeled, or padded with a synthetic user turn. Empty turns were
        # already skipped by append_content, so contents.last IS the last
        # nonempty turn.
        def reject_assistant_last_input(contents)
          last_content = contents.last
          return if last_content.nil?
          return unless last_content[:role] == "model"

          raise SimpleInference::ValidationError,
                "the last nonempty input turn is assistant (wire role \"model\") — gemini generateContent " \
                "requires a user-last request (frozen conformance-register disposition)"
        end

        def append_entry(contents, entry, function_names)
          if entry["type"].to_s == "function_call"
            call_id = entry["call_id"] || entry["id"]
            arguments = parse_arguments(entry["arguments"])
            function_names[call_id] = entry["name"] if call_id && entry["name"]

            append_content(
              contents,
              role: "model",
              parts: [
                function_call_part(
                  name: entry["name"],
                  arguments: arguments,
                  call_id: call_id,
                  provider_payload: entry["provider_payload"]
                ),
              ]
            )
            return
          end

          if entry["type"].to_s == "function_call_output"
            call_id = entry["call_id"]
            tool_name = entry["name"] || function_names[call_id]
            raise SimpleInference::ValidationError, "function_call_output is missing a tool name for #{call_id}" if tool_name.to_s.empty?

            append_content(
              contents,
              role: "user",
              parts: [
                {
                  # .compact: when history lacks a call id the reference client
                  # omits the id key entirely; never send "id": null.
                  functionResponse: {
                    name: tool_name,
                    response: normalize_function_response(entry["output"]),
                    id: call_id,
                  }.compact,
                },
              ]
            )
            return
          end

          role = normalize_role(entry["role"])
          parts = normalize_message_parts(entry, function_names)
          append_content(contents, role: role, parts: parts) if role && parts.any?
        end

        # The closed role vocabulary this lane lowers ("system" is peeled off
        # into systemInstruction before this point; "tool" results ride
        # user-role functionResponse parts per the Gemini wire). The old silent
        # unknown-role -> "user" relabel is dead: an unknown role is a loud
        # pre-wire error and never reaches the wire. `developer` is the one
        # KNOWN role of the Responses family with no twin on this wire: it
        # lowers to `user` so it stays WHERE THE CALLER PLACED IT in the list
        # — hoisting it into systemInstruction would move it ahead of
        # everything behind it (Nexus S-F r2 (5)).
        def normalize_role(role)
          case role.to_s
          when "user"
            "user"
          when "assistant", "model"
            "model"
          when "tool"
            "user"
          when "developer"
            "user"
          else
            raise SimpleInference::ValidationError,
                  "unsupported message role #{role.inspect} for gemini generateContent " \
                  "(accepted: #{ACCEPTED_ROLES.join(", ")}) — unknown roles are never relabeled"
          end
        end

        def normalize_message_parts(entry, function_names)
          if entry["role"].to_s == "tool"
            call_id = entry["tool_call_id"] || entry["call_id"]
            tool_name = entry["name"] || function_names[call_id]
            raise SimpleInference::ValidationError, "tool result message is missing a tool name for #{call_id}" if tool_name.to_s.empty?

            return [
              {
                # .compact: same rule as the function_call_output replay path;
                # an absent call id means NO id key on the wire.
                functionResponse: {
                  name: tool_name,
                  response: normalize_function_response(entry["content"]),
                  id: call_id,
                }.compact,
              },
            ]
          end

          normalize_content_parts(entry["content"]) + normalize_tool_call_parts(entry["tool_calls"], function_names)
        end

        def normalize_content_parts(content)
          case content
          when Array
            content.filter_map { |part| normalize_content_part(part) }
          when nil
            []
          else
            text = content.to_s
            text.empty? ? [] : [{ text: text }]
          end
        end

        # A scalar part is the caller's shorthand for a text part — normalized
        # once here, at the lowering boundary.
        def normalize_content_part(part)
          return { text: part.to_s } unless part.is_a?(Hash)

          normalized = Internal::Keys.shallow_stringify(part)
          type = normalized["type"].to_s

          case type
          when "", "text", "input_text", "output_text"
            text = normalized["text"].to_s
            text.empty? ? nil : { text: text }
          when "input_image", "image", "image_url"
            normalize_image_content_part(normalized)
          when "input_file"
            media = input_file_media(normalized)
            { inline_data: { mime_type: media.media_type, data: [media.bytes].pack("m0") } }
          when "thought"
            # Replayed prior-turn reasoning as a native Gemini thought part. The signature is
            # optional and strictly validated when present, so a replayed thought is unsigned
            # (always accepted); attach thoughtSignature only when the caller supplies one.
            text = normalized["text"].to_s
            return nil if text.empty?

            part = { thought: true, text: text }
            signature = thought_signature_of(normalized)
            part[:thoughtSignature] = signature if signature.to_s.length.positive?
            part
          else
            raise SimpleInference::ValidationError, "unsupported gemini content part #{type.inspect}"
          end
        end

        # Media ingress is BYTES-ONLY (transport policy, register Input-media
        # profiles v1): an image part carries a SimpleInference::MediaInput and
        # lowers to the inline_data base64 wire form here — the lane builds the
        # base64 payload from verified bytes itself. Caller data URIs, http(s)
        # URLs, host paths, and provider file handles are loud rejections at
        # this lowering — never forwarded.
        def normalize_image_content_part(part)
          media = image_media_carrier(part)
          unless media.is_a?(SimpleInference::MediaInput)
            raise SimpleInference::ValidationError,
                  "gemini image content parts carry raw bytes via SimpleInference::MediaInput — " \
                  "caller data URIs, http(s) URLs, host paths, and provider file handles are " \
                  "rejected at this lane's lowering (transport policy: prepared bytes embed " \
                  "inline as base64; got #{media.class})"
          end

          {
            inline_data: {
              mime_type: media.media_type,
              data: [media.bytes].pack("m0"),
            },
          }
        end

        # The carrier may arrive under the chat-family spelling (image_url,
        # possibly nested under "url"); only a MediaInput found there is
        # acceptable — unwrapping the nested hash exposes string URL/data-URI
        # carriers to the rejection above.
        def image_media_carrier(part)
          carrier = part["image_url"] || part["url"]
          carrier = carrier["url"] if carrier.is_a?(Hash) && carrier.key?("url")
          carrier
        end

        # Flat ({"name","arguments"}) or nested ({"function" => {...}}) calls.
        def normalize_tool_call_parts(tool_calls, function_names)
          Array(tool_calls).map do |tool_call|
            normalized = Internal::Keys.shallow_stringify(tool_call)
            call_id = normalized["id"] || normalized["call_id"]
            function = normalized["function"].nil? ? normalized : Internal::Keys.shallow_stringify(normalized["function"])
            function_names[call_id] = function["name"] if call_id && function["name"]

            function_call_part(
              name: function["name"],
              arguments: parse_arguments(function["arguments"] || normalized["arguments"]),
              call_id: call_id,
              provider_payload: normalized["provider_payload"]
            )
          end
        end

        def function_call_part(name:, arguments:, call_id:, provider_payload: nil)
          normalized_payload = Internal::Keys.shallow_stringify(provider_payload)
          function_call = normalized_payload["functionCall"]
          unless function_call.nil?
            normalized_call = Internal::Keys.shallow_stringify(function_call)
            normalized_call["id"] ||= call_id if call_id
            part = { functionCall: normalized_call }
            thought_signature = thought_signature_of(normalized_payload)
            part[:thoughtSignature] = thought_signature if thought_signature
            return part
          end

          {
            functionCall: {
              name: name,
              args: arguments || {},
              id: call_id,
            }.compact,
          }
        end

        def append_content(contents, role:, parts:)
          return if role.to_s.empty? || Array(parts).empty?

          if contents.last&.fetch(:role, nil) == role
            contents.last[:parts].concat(Array(parts))
          else
            contents << {
              role: role,
              parts: Array(parts),
            }
          end
        end

        def normalize_tools(tools)
          declarations = Array(tools).filter_map do |tool|
            normalized = tool
            next unless normalized[:type] == "function"

            function = normalized[:function] || normalized

            {
              name: function[:name],
              description: function[:description],
              parameters: convert_tool_schema_to_gemini(function[:parameters] || normalized[:parameters]),
            }.compact
          end

          return [] if declarations.empty?

          [{ functionDeclarations: declarations }]
        end

        def build_tool_config(tool_choice)
          normalized_choice = normalize_tool_choice(tool_choice)
          return nil if normalized_choice.nil?

          config = {
            mode: forced_tool_choice?(normalized_choice) ? "any" : normalized_choice,
          }
          config[:allowedFunctionNames] = [normalized_choice] if specific_tool_choice?(normalized_choice)
          { functionCallingConfig: config }
        end

        def normalize_tool_choice(tool_choice)
          return nil if tool_choice.nil?

          # The wire's declared union: a mode string, or the function envelope.
          case tool_choice
          when Hash
            normalized = tool_choice
            type = normalized[:type]
            return normalized.dig(:function, :name) || normalized[:name] if type == "function"
            return type if type.is_a?(String) && !type.empty?
          when String
            value = tool_choice
            return nil if value.empty?

            return value
          else
            nil
          end

          nil
        end

        def forced_tool_choice?(tool_choice)
          tool_choice == "required" || specific_tool_choice?(tool_choice)
        end

        def specific_tool_choice?(tool_choice)
          !%w[auto none required].include?(tool_choice)
        end

        def convert_tool_schema_to_gemini(schema)
          return nil if schema.nil?

          normalized_schema = Internal::Keys.deep_stringify(schema)
          unless normalized_schema["type"].to_s == "object"
            raise SimpleInference::ValidationError, "Gemini tool parameters must be objects"
          end

          {
            type: "OBJECT",
            properties: normalized_schema.fetch("properties", {}).transform_values { |property| convert_tool_property(property) },
            required: Array(normalized_schema["required"]).map(&:to_s),
          }
        end

        def convert_tool_property(property_schema)
          raw_schema = Internal::Keys.deep_stringify(property_schema)
          union_property = convert_multi_member_any_of(raw_schema)
          return union_property if union_property

          working_schema = normalize_any_of_schema(raw_schema) || raw_schema
          type = gemini_schema_type(working_schema["type"])

          property = { type: type }
          copy_tool_attributes(property, raw_schema, %w[description enum format nullable maximum minimum multipleOf])
          copy_tool_attributes(property, working_schema, %w[description enum format nullable maximum minimum multipleOf])

          case type
          when "ARRAY"
            items_schema = working_schema["items"] || raw_schema["items"] || { "type" => "string" }
            property[:items] = convert_tool_property(items_schema)
            copy_tool_attributes(property, working_schema, %w[minItems maxItems])
            copy_tool_attributes(property, raw_schema, %w[minItems maxItems])
          when "OBJECT"
            property[:properties] = working_schema.fetch("properties", {}).transform_values { |child| convert_tool_property(child) }
            required = working_schema["required"] || raw_schema["required"]
            property[:required] = Array(required).map(&:to_s) if required
          else
            nil
          end

          property
        end

        def copy_tool_attributes(target, source, attributes)
          attributes.each do |attribute|
            value = schema_value(source, attribute)
            next if value.nil?

            target[attribute.to_sym] = value
          end
        end

        # Multi-member unions survive as anyOf, matching python-genai
        # (_transformers.py process_schema recurses into every anyOf member and
        # _handle_null_fields flattens ONLY when a single member remains): each
        # non-null member is converted through the normal property conversion,
        # the null member becomes nullable:true on the parent, and no type is
        # set alongside anyOf. Returns nil for 0..1 non-null members, which
        # keeps the single-member flatten path (normalize_any_of_schema) intact.
        def convert_multi_member_any_of(raw_schema)
          null_entries, non_null_entries = partition_any_of_entries(raw_schema)
          return nil unless non_null_entries && non_null_entries.size >= 2

          property = { anyOf: non_null_entries.map { |entry| convert_tool_property(entry) } }
          copy_tool_attributes(property, raw_schema, %w[description enum format nullable maximum minimum multipleOf])
          property[:nullable] = true if null_entries.any?
          property
        end

        def partition_any_of_entries(schema)
          any_of = schema["anyOf"]
          return [nil, nil] unless any_of.is_a?(Array) && any_of.any?

          normalized_entries = any_of.map { |entry| Internal::Keys.deep_stringify(entry) }
          normalized_entries.partition { |entry| schema_type(entry).to_s == "null" }
        end

        def normalize_any_of_schema(schema)
          null_entries, non_null_entries = partition_any_of_entries(schema)
          return nil if non_null_entries.nil?

          if non_null_entries.size == 1 && null_entries.any?
            normalized = Internal::Keys.deep_stringify(non_null_entries.first)
            normalized["nullable"] = true
            normalized
          elsif non_null_entries.any?
            Internal::Keys.deep_stringify(non_null_entries.first)
          else
            { "type" => "string", "nullable" => true }
          end
        end

        def schema_value(source, attribute)
          case attribute
          when "multipleOf"
            source["multipleOf"] || source["multiple_of"]
          when "minItems"
            source["minItems"] || source["min_items"]
          when "maxItems"
            source["maxItems"] || source["max_items"]
          else
            source[attribute]
          end
        end

        def schema_type(schema)
          schema["type"]
        end

        def gemini_schema_type(type)
          case type.to_s.downcase
          when "integer"
            "INTEGER"
          when "number", "float", "double"
            "NUMBER"
          when "boolean"
            "BOOLEAN"
          when "array"
            "ARRAY"
          when "object"
            "OBJECT"
          else
            "STRING"
          end
        end
      end
    end
  end
end
