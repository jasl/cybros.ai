module SimpleInference
  module Protocols
    class AnthropicMessages
      # Canonical request inputs and options lowered into this protocol's body.
      module RequestBody
        private

        def build_request_body(model:, input:, options:)
          reject_inventoried_options(options)

          system, messages = coerce_messages(input, options)
          reject_assistant_last(messages)

          body = {
            model: model,
            max_tokens: required_max_tokens(options[:max_output_tokens]),
            messages: messages,
          }

          # `system` is a String (cache off — byte-identical to before) or a
          # structured block array (the kernel marked a block with cache_control);
          # build_system already returns nil when empty.
          body[:system] = system unless system.nil?

          tools = normalize_tools(options[:tools])
          body[:tools] = tools if tools.any?
          tool_choice = build_tool_choice(
            tool_choice: options[:tool_choice],
            parallel_tool_calls: if options.key?(:parallel_tool_calls)
                                   options[:parallel_tool_calls]
                                 end
          )
          body[:tool_choice] = tool_choice if tool_choice

          body[:temperature] = options[:temperature] if options.key?(:temperature)
          body[:top_p] = options[:top_p] if options.key?(:top_p)
          body[:top_k] = options[:top_k] if options.key?(:top_k)
          apply_thinking_options(body, options)

          body
        end

        # `max_tokens` is a REQUIRED Messages field and the caller's fact (the
        # row's max_output_tokens generation parameter, defaulting to the
        # model's output limit). Until 2026-09-16 a missing value fell back to
        # 1024 — a silent ceiling on every turn, cutting any tool call over
        # ~1k tokens. opencode's fallback is the model's output limit, else
        # 4096 (anthropic-messages.ts:521,571), never 1024; this protocol
        # invents no number at all: a row without the parameter fails loudly
        # here, mirroring the manual-thinking refusal below.
        def required_max_tokens(value)
          return value if value.is_a?(Integer) && value.positive?

          raise SimpleInference::ValidationError,
                "max_output_tokens is required on this wire (max_tokens is a required Messages field; " \
                "declare the row's max_output_tokens generation parameter — got #{value.inspect})"
        end

        # Inventoried local rejections replacing the former silent drops. Each
        # rejection is deterministic, happens pre-IO, and names its reason.
        def reject_inventoried_options(options)
          return unless options.key?(:n)

          raise SimpleInference::ValidationError,
                "anthropic_messages locally rejects n (result_count): /v1/messages has no " \
                "multi-candidate concept and rejects unknown top-level fields with a 400; " \
                "remove the option instead of expecting a silent drop"
        end

        # Register final-turn disposition: the lane rejects a last nonempty
        # assistant prefill; prior assistant history remains eligible. Rejected
        # pre-flight (zero outbound IO), never dropped/relabeled/padded.
        def reject_assistant_last(messages)
          return unless messages.last && messages.last[:role].to_s == "assistant"

          raise SimpleInference::ValidationError,
                "anthropic_messages rejects assistant-last input: the final nonempty turn must " \
                "not be an assistant prefill (prior assistant turns remain eligible)"
        end

        # Faithful lowering, no model dispatch: reasoning_effort "none" becomes
        # the explicit wire disable; an in-vocabulary effort rides adaptive mode
        # plus output_config.effort; a caller-supplied thinking Hash reaches the
        # wire verbatim (manual budgets are ONLY ever caller-chosen). Server-side
        # legality of a mode on a given model is the caller/profile's contract.
        def apply_thinking_options(body, options)
          enabled = validated_reasoning_enabled(options[:reasoning_enabled], effort: options[:reasoning_effort])
          effort = validated_reasoning_effort(options[:reasoning_effort]) unless enabled == false
          thinking = bind_thinking(anthropic_thinking_config(effort, options[:thinking], enabled: enabled))
          body[:thinking] = thinking if thinking
          validate_manual_thinking(thinking, body)

          output_config = anthropic_output_config(options, effort: effort, enabled: enabled)
          body[:output_config] = output_config if output_config
        end

        # The row's `thinking_binding` fact lowers to
        # thinking.block_binding.prefix_mismatch_behavior on adaptive AND
        # manual enabled thinking (the two modes that produce signed blocks),
        # never on disabled; a caller's explicit block_binding wins, as
        # opencode's does (transform.ts:729). The beta follows the field
        # (protocol_headers).
        def bind_thinking(thinking)
          return thinking if @thinking_binding.nil? || thinking.nil?
          return thinking unless %w[adaptive enabled].include?(thinking[:type].to_s)
          return thinking if thinking.key?(:block_binding)

          thinking.merge(block_binding: { prefix_mismatch_behavior: @thinking_binding })
        end

        def validated_reasoning_effort(effort)
          return nil if effort.nil?

          value = effort.to_s
          return value if value == "none" || REASONING_EFFORT_VOCABULARY.include?(value)

          raise SimpleInference::ValidationError,
                "anthropic_messages accepts reasoning_effort none|#{REASONING_EFFORT_VOCABULARY.join("|")} " \
                "(got #{value.inspect}); efforts lower faithfully — this protocol never clamps"
        end

        def anthropic_thinking_config(effort, explicit_thinking, enabled:)
          return { type: "disabled" } if enabled == false

          unless explicit_thinking.nil?
            thinking = Internal::Keys.shallow_symbolize(explicit_thinking)
            ensure_effort_thinking_consistency(effort, thinking)
            return thinking
          end

          return nil if effort.nil? && enabled.nil?

          # display: "summarized" is this lane's CAPTURE DEFAULT (the
          # reasoning-capture posture, like the responses family's
          # store:false + encrypted include): "omitted" — the wire's own
          # default on the Claude 5 family — returns signature-only blocks
          # with empty text, which replay same-model but leave nothing to
          # display or to carry across a model switch. Summaries bill the
          # same as omitted (display controls visibility only). A caller's
          # explicit :thinking hash overrides, as everywhere on this lane.
          effort == "none" ? { type: "disabled" } : { type: "adaptive", display: "summarized" }
        end

        # Effort rides output_config.effort in adaptive mode only; pairing it
        # with a manual/disabled thinking Hash is a contradiction the caller
        # must resolve — silently dropping either side would hide a decision.
        def ensure_effort_thinking_consistency(effort, thinking)
          return if effort.nil?

          type = thinking[:type].to_s
          return if effort == "none" ? type == "disabled" : type == "adaptive"

          raise SimpleInference::ValidationError,
                "reasoning_effort #{effort.inspect} conflicts with explicit thinking type #{type.inspect}: " \
                "effort rides output_config.effort in adaptive mode only (\"none\" pairs with type \"disabled\")"
        end

        # Manual mode is caller-chosen; the protocol validates the register's
        # hard bounds instead of silently repairing the request (the old code
        # bumped max_tokens to budget+1024 behind the caller's back).
        def validate_manual_thinking(thinking, body)
          return unless thinking && thinking[:type].to_s == "enabled"

          budget = thinking[:budget_tokens]
          unless budget.is_a?(Integer) && budget >= MANUAL_THINKING_BUDGET_MINIMUM
            raise SimpleInference::ValidationError,
                  "thinking.budget_tokens must be an Integer >= #{MANUAL_THINKING_BUDGET_MINIMUM} " \
                  "(got #{budget.inspect})"
          end

          max_tokens = body[:max_tokens].to_i
          return if max_tokens > budget

          raise SimpleInference::ValidationError,
                "max_tokens (#{max_tokens}) must exceed thinking.budget_tokens (#{budget}); " \
                "pass a larger max_output_tokens — the protocol no longer bumps it silently"
        end

        def anthropic_output_config(options, effort:, enabled:)
          output_config = Internal::Keys.shallow_symbolize(options[:output_config])
          output_config = output_config.except(:effort) if enabled == false
          output_config[:effort] = effort if effort && effort != "none" && !output_config.key?(:effort)
          format = anthropic_output_format(options[:response_format])
          output_config[:format] = format if format && !output_config.key?(:format)

          output_config.empty? ? nil : output_config
        end

        # GA structured output: output_config.format only accepts the
        # json_schema variant (reference: json_output_format.rb). Any other
        # envelope type (json_object included) has no Anthropic equivalent and
        # is a loud inventoried rejection, never a silent drop.
        # The caller's response_format enters here once: an envelope Hash whose
        # json_schema variant carries a schema Hash (flat, or nested OpenAI-style
        # under json_schema:).
        def anthropic_output_format(response_format)
          return nil if response_format.nil?

          unless response_format.is_a?(Hash)
            raise SimpleInference::ValidationError, "response_format must be a Hash"
          end

          envelope = Internal::Keys.shallow_symbolize(response_format)
          type = envelope[:type].to_s
          unless type == "json_schema"
            raise SimpleInference::ValidationError,
                  "anthropic_messages locally rejects response_format type #{type.inspect}: " \
                  "output_config.format accepts only json_schema (no Anthropic equivalent exists)"
          end

          schema = envelope[:schema] || Internal::Keys.shallow_symbolize(envelope[:json_schema])[:schema]
          raise SimpleInference::ValidationError, "response_format json_schema requires a schema Hash" unless schema.is_a?(Hash)

          { type: "json_schema", schema: schema }
        end

        # The caller's input enters here once: a String, or an Array whose
        # entries are message Hashes or bare user strings.
        #
        # System entries split by POSITION (alignment 2026-09-16, F11): the
        # LEADING run (every system entry before the first wire message) is
        # hoisted into the top-level `system` field on every row; a NON-LEADING
        # one stays WHERE THE CALLER PLACED IT — hoisting it reordered history
        # ahead of the turns it followed, which breaks the cached prefix and
        # the thinking-block binding alike. In place it is a wire
        # `role: system` message under the row's `mid_conversation_system`
        # fact, else user text (the developer-role rule, normalize_role).
        def coerce_messages(input, options)
          entries = input.is_a?(Array) ? input : [{ role: "user", content: input }]
          entries = entries.map { |entry| entry.is_a?(Hash) ? Internal::Keys.shallow_stringify(entry) : { "role" => "user", "content" => entry } }

          system_segments = system_segments_from_instructions(options[:instructions])

          messages = []

          entries.each do |entry|
            if entry["role"].to_s == "system"
              if messages.empty? && !entry.key?("output_config")
                system_segments.concat(system_segments_from_message_content(entry["content"]))
              else
                append_system_update(messages, entry)
              end
              next
            end

            reject_non_assistant_after_system_update(messages, entry)
            append_entry(messages, entry)
          end

          [build_system(system_segments), messages]
        end

        # A non-leading system entry. Under the row fact it is the vendor's
        # in-place system message — text blocks (cache_control kept) and, for
        # the migration guide's effort-change recipe, an `output_config` on an
        # empty-content entry (F13's gem half; its beta follows the field).
        # Without the fact the text lowers in place to a user block; an
        # output_config entry has no lowering there and refuses.
        def append_system_update(messages, entry)
          blocks = system_segments_from_message_content(entry["content"]).filter_map { |segment| system_wire_block(segment) }
          output_config = entry["output_config"]

          if @mid_conversation_system
            return if blocks.empty? && output_config.nil?

            ensure_system_update_placement(messages)
            message = { role: "system", content: blocks }
            message[:output_config] = validated_system_output_config(output_config) unless output_config.nil?
            messages << message
          elsif output_config.nil?
            append_message(messages, role: "user", content: blocks)
          else
            raise SimpleInference::ValidationError,
                  "a system entry carrying output_config has no lowering on this row: it is a " \
                  "mid-conversation system message, which needs the row's mid_conversation_system fact"
          end
        end

        def validated_system_output_config(value)
          return Internal::Keys.shallow_symbolize(value) if value.is_a?(Hash) && !value.empty?

          raise SimpleInference::ValidationError,
                "a system entry's output_config must be a non-empty Hash (got #{value.inspect})"
        end

        # opencode's placement guard (anthropic-messages.ts canUseNativeSystemUpdate)
        # as a local refusal, since the vendor 400s the same shapes: the entry
        # must follow a user turn (tool results lower to one), so never
        # messages[0], never an assistant turn (an unanswered tool call
        # included), never another system message.
        def ensure_system_update_placement(messages)
          return if messages.last && messages.last[:role] == "user"

          raise SimpleInference::ValidationError,
                "a mid-conversation system entry must follow a user turn (or tool results) — never the first " \
                "message, never an assistant turn, never another system entry; the wire rejects these shapes"
        end

        # The other half of the guard: what follows an in-place system message
        # must be the assistant's turn (or the end of the input).
        def reject_non_assistant_after_system_update(messages, entry)
          return unless messages.last && messages.last[:role] == "system"
          return if entry["type"].to_s == "function_call"
          return if entry["type"].to_s != "function_call_output" && normalize_role(entry["role"]) == "assistant"

          raise SimpleInference::ValidationError,
                "the turn after a mid-conversation system entry must be the assistant's — a user turn or a " \
                "tool result there is a shape the wire rejects"
        end

        # instructions is a plain String (joined, cache off) or an Array of system
        # blocks the kernel marked with cache_control. Every segment becomes one
        # {"text", "cache_control"} pair; build_system decides the wire shape.
        def system_segments_from_instructions(instructions)
          case instructions
          when Array
            instructions.filter_map { |block| system_segment_from(block) }
          when nil
            []
          else
            [system_segment_from(instructions.to_s)].compact
          end
        end

        # A block is the caller's bare String or a {text, cache_control} Hash —
        # the declared union of the instructions array.
        def system_segment_from(block)
          case block
          when String
            block.strip.empty? ? nil : { "text" => block, "cache_control" => nil }
          when Hash
            normalized = Internal::Keys.shallow_stringify(block)
            text = normalized["text"].to_s
            text.empty? ? nil : { "text" => text, "cache_control" => normalized["cache_control"] }
          else
            nil
          end
        end

        def system_segments_from_message_content(content)
          case content
          when Array
            content.filter_map { |block| system_segment_from(block) }
          when Hash
            [system_segment_from(content)].compact
          else
            [system_segment_from(content.to_s)].compact
          end
        end

        # A String `system` when every segment is plain (byte-identical to the
        # pre-caching behaviour); a structured block array the moment one segment
        # carries cache_control. Returns nil when empty either way.
        def build_system(system_segments)
          return nil if system_segments.empty?

          if system_segments.none? { |segment| segment["cache_control"] }
            text = system_segments.map { |segment| segment["text"] }.join("\n\n").strip
            text.empty? ? nil : text
          else
            blocks = system_segments.filter_map { |segment| system_wire_block(segment) }
            blocks.empty? ? nil : blocks
          end
        end

        def system_wire_block(segment)
          return nil if segment["text"].strip.empty?

          block = { type: "text", text: segment["text"] }
          block[:cache_control] = segment["cache_control"] if segment["cache_control"]
          block
        end

        # Forward a caller-supplied cache_control from an already-normalized
        # source entry onto the freshly built wire block. Coverage is the block
        # types the kernel's placement can mark today — system/text/image/
        # tool_result; tools and tool_use passthrough is deliberately absent
        # (the kernel never marks them; a system-block marker already caches
        # tools, which render first), and thinking blocks reject cache_control
        # upstream (Anthropic 400).
        def with_cache_control(block, source)
          cache_control = source["cache_control"]
          cache_control ? block.merge(cache_control: cache_control) : block
        end

        def append_entry(messages, entry)
          if entry["type"].to_s == "function_call"
            append_message(
              messages,
              role: "assistant",
              content: [
                {
                  type: "tool_use",
                  id: wire_tool_id(entry["call_id"] || entry["id"]),
                  name: entry["name"],
                  input: parse_arguments(entry["arguments"]),
                }.compact,
              ]
            )
            return
          end

          if entry["type"].to_s == "function_call_output"
            append_message(
              messages,
              role: "user",
              content: [tool_result_block(entry, tool_use_id: entry["call_id"], content: entry["output"])]
            )
            return
          end

          role = normalize_role(entry["role"])
          content = normalize_message_content(entry)
          append_message(messages, role: role, content: content) if role && content.any?
        end

        # The ONE tool_result lowering for both input spellings. `is_error` is
        # the wire's own field (alignment 2026-09-16, F7 — opencode
        # anthropic-messages.ts:481, claude-code toolExecution.ts:480): the
        # neutral payload's flag lowers to it, absent when false; the text
        # marker the consumer puts in the content stays beside it, as
        # claude-code sends both.
        def tool_result_block(entry, tool_use_id:, content:)
          with_cache_control(
            {
              type: "tool_result",
              tool_use_id: wire_tool_id(tool_use_id),
              content: stringify_content(content),
              is_error: (true if entry["is_error"]),
            }.compact,
            entry
          )
        end

        # An unknown role is a loud refusal, never a passenger. This fell
        # through to `role.to_s` and `append_message` then put it on the wire
        # verbatim — so an unknown role reached Anthropic and came back a
        # 400. Its sibling lane already refused the same way ("unknown roles
        # are never relabeled"); this one simply never said so. `developer` is
        # the one KNOWN role of the sibling family with no twin on this wire:
        # it lowers to `user` so it stays WHERE THE CALLER PLACED IT in the
        # list — hoisting it into the system field would move it ahead of
        # everything behind it (Nexus S-F r2 (5)).
        def normalize_role(role)
          case role.to_s
          when "assistant", "model"
            "assistant"
          when "tool", "user", ""
            "user"
          when "developer"
            "user"
          else
            raise SimpleInference::ValidationError,
                  "unsupported message role #{role.inspect} for anthropic messages " \
                  "(accepted: #{ACCEPTED_ROLES.join(", ")}) — unknown roles are never relabeled"
          end
        end

        def normalize_message_content(entry)
          if entry["role"].to_s == "tool"
            return [tool_result_block(entry, tool_use_id: entry["tool_call_id"] || entry["call_id"], content: entry["content"])]
          end

          normalize_content_blocks(entry["content"]) + normalize_tool_call_blocks(entry["tool_calls"])
        end

        def normalize_content_blocks(content)
          case content
          when Array
            content.filter_map { |part| normalize_content_part(part) }
          when nil
            []
          else
            text = content.to_s
            text.empty? ? [] : [{ type: "text", text: text }]
          end
        end

        # A scalar part is the caller's shorthand for a text part — normalized
        # once here, at the lowering boundary.
        def normalize_content_part(part)
          return { type: "text", text: part.to_s } unless part.is_a?(Hash)

          normalized = Internal::Keys.shallow_stringify(part)
          type = normalized["type"].to_s

          case type
          when "", "text", "input_text", "output_text"
            text = normalized["text"].to_s
            text.empty? ? nil : with_cache_control({ type: "text", text: text }, normalized)
          when "input_image", "image", "image_url"
            with_cache_control(normalize_image_content_part(normalized), normalized)
          when "input_file"
            media = input_file_media(normalized)
            with_cache_control({
              type: "document",
              source: { type: "base64", media_type: media.media_type, data: [media.bytes].pack("m0") },
            }, normalized)
          when "thinking"
            # Replayed prior-turn reasoning. Anthropic rejects a signature-less thinking
            # block (400), so drop the block rather than emit one that cannot validate.
            # EMPTY thinking text is a different matter: Claude 5's adaptive thinking
            # returns signature-only blocks (thinking: "", signature present) and the
            # continuation contract is replay-verbatim — live-probed 2026-08-29.
            thinking = normalized["thinking"].to_s
            signature = normalized["signature"].to_s
            return nil if signature.empty?

            { type: "thinking", thinking: thinking, signature: signature }
          when "redacted_thinking"
            # Opaque encrypted reasoning from a prior turn; the API expects it
            # replayed verbatim (reference: redacted_thinking_block_param.rb).
            { type: "redacted_thinking", data: normalized["data"].to_s }
          else
            raise SimpleInference::ValidationError, "unsupported anthropic content part #{type.inspect}"
          end
        end

        # Media ingress is BYTES-ONLY (transport policy, register Input-media
        # profiles v1): an image part carries a SimpleInference::MediaInput and
        # lowers to the `source.type: base64` wire block here — the lane builds
        # the base64 form from verified bytes itself. Caller data URIs, http(s)
        # URLs, host paths, and provider file handles are loud rejections at
        # this lowering — never forwarded, even though the Anthropic wire would
        # accept a url source.
        def normalize_image_content_part(part)
          media = image_media_carrier(part)
          unless media.is_a?(SimpleInference::MediaInput)
            raise SimpleInference::ValidationError,
                  "anthropic image content parts carry raw bytes via SimpleInference::MediaInput — " \
                  "caller data URIs, http(s) URLs, host paths, and provider file handles are " \
                  "rejected at this lane's lowering (transport policy: prepared bytes embed " \
                  "inline as base64; got #{media.class})"
          end

          {
            type: "image",
            source: {
              type: "base64",
              media_type: media.media_type,
              data: [media.bytes].pack("m0"),
            },
          }
        end

        # The carrier may arrive under the chat-family spelling (image_url,
        # possibly nested under "url") or the Anthropic-native source key; only
        # a MediaInput found there is acceptable, and unwrapping the nested
        # hash exposes string URL/data-URI carriers to the rejection above.
        def image_media_carrier(part)
          carrier = part["image_url"] || part["url"] || part["source"]
          carrier = carrier["url"] || carrier["data"] || carrier if carrier.is_a?(Hash)
          carrier
        end

        # Flat ({"name","arguments"}) or nested ({"function" => {...}}) calls.
        def normalize_tool_call_blocks(tool_calls)
          Array(tool_calls).map do |tool_call|
            normalized = Internal::Keys.shallow_stringify(tool_call)
            call_id = normalized["id"] || normalized["call_id"]
            function = normalized["function"].nil? ? normalized : Internal::Keys.shallow_stringify(normalized["function"])

            {
              type: "tool_use",
              id: wire_tool_id(call_id),
              name: function["name"],
              input: parse_arguments(function["arguments"] || normalized["arguments"]),
            }.compact
          end
        end

        def wire_tool_id(id) = id&.to_s&.gsub(TOOL_ID_REFUSED, "_")

        def append_message(messages, role:, content:)
          return if role.to_s.empty? || Array(content).empty?

          if messages.last&.fetch(:role, nil) == role
            messages.last[:content].concat(Array(content))
          else
            messages << {
              role: role,
              content: Array(content),
            }
          end
        end

        def normalize_tools(tools)
          Array(tools).filter_map do |tool|
            normalized = tool
            next unless normalized[:type] == "function"

            function = normalized[:function] || normalized

            # strict is a top-level tool field in the Anthropic API (reference:
            # tool.rb), not a JSON Schema keyword; accept the OpenAI-style flat
            # or nested placement and hoist it.
            strict = function.key?(:strict) ? function[:strict] : normalized[:strict]

            {
              name: function[:name],
              description: function[:description],
              input_schema: function[:parameters] || normalized[:parameters] || default_input_schema,
              strict: strict,
            }.compact
          end
        end

        def build_tool_choice(tool_choice:, parallel_tool_calls:)
          return nil if tool_choice.nil? && parallel_tool_calls.nil?

          normalized_choice = normalize_tool_choice(tool_choice)
          return nil if normalized_choice.nil? && parallel_tool_calls.nil?

          normalized_choice ||= "auto"
          choice = {
            type: case normalized_choice
                  when "auto", "none"
                    normalized_choice
                  when "required"
                    "any"
                  else
                    "tool"
                  end,
          }
          choice[:name] = normalized_choice if choice[:type] == "tool"
          choice[:disable_parallel_tool_use] = !parallel_tool_calls if !parallel_tool_calls.nil? && choice[:type] != "none"
          choice
        end

        def normalize_tool_choice(tool_choice)
          return nil if tool_choice.nil?

          # The wire's declared union: a mode string, or the function envelope.
          case tool_choice
          when Hash
            normalized = tool_choice
            type = normalized[:type]
            return normalized.dig(:function, :name) || normalized[:name] if type == "function"

            type if type.is_a?(String) && !type.empty?
          when String
            value = tool_choice
            value.empty? ? nil : value
          else
            nil
          end
        end

        def default_input_schema
          {
            type: "object",
            properties: {},
            required: [],
            additionalProperties: false,
          }
        end
      end
    end
  end
end
