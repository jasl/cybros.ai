module SimpleInference
  module Protocols
    class OpenAIResponses
      # Canonical request inputs and options lowered into this protocol's body.
      module RequestBody
        private

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
        # (transport policy, register Input-media profiles v1): input_image and
        # input_file parts carry a SimpleInference::MediaInput and lower to the inline
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
          case responses_part_field(part, "type").to_s
          when "input_file"
            lower_responses_file_part(Internal::Keys.shallow_stringify(part))
          when "input_image"
            lower_responses_image_part(part)
          else
            part
          end
        end

        def lower_responses_file_part(part)
          media = input_file_media(part)
          part.merge(
            "filename" => input_file_filename(part),
            "file_data" => "data:#{media.media_type};base64,#{[media.bytes].pack("m0")}",
          )
        end

        def lower_responses_image_part(part)
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
      end
    end
  end
end
