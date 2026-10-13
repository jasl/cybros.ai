require_relative "base"

module SimpleInference
  module Protocols
    class GeminiGenerateContent < Base
      require_relative "gemini_generate_content/request_body"

      include RequestBody

      # What this wire accepts — the consumer's admission reads it, so it
      # lists what normalize_role admits: `developer` lowers to `user` in
      # place there and is accepted here.
      ACCEPTED_ROLES = %w[system developer user assistant tool].freeze

      # A stream that ran to HTTP completion without any candidate carrying a
      # finishReason — an interruption, never a silent normal Result. A
      # subclass of the SHARED cross-protocol interruption error, so it
      # carries the same classification contract (provider_protocol_error /
      # counted_failure) as every other lane's missing-terminal raise.
      class InterruptedStreamError < SimpleInference::ProviderStreamInterruptedError; end

      # A wire finishReason or blockReason outside its frozen released-SDK
      # enum — fail closed instead of classifying an unknown terminal
      # vocabulary.
      class UnknownFinishReasonError < SimpleInference::Error; end

      # The fold over one generateContent stream: output items under
      # assembly, the latest usage snapshot (each chunk REPLACES the previous
      # one — the last seen is authoritative, and survives a bare terminal
      # chunk), prompt feedback, and the terminal finishReason.
      class StreamFold
        attr_accessor :output_items, :latest_usage_metadata, :prompt_feedback, :finish_reason
        attr_reader :events_seen

        def initialize
          @output_items = []
          @latest_usage_metadata = nil
          @prompt_feedback = {}
          @finish_reason = nil
          @events_seen = 0
        end

        def count_event = @events_seen += 1
      end

      # Supported FinishReason vocabulary: the released SDK's original
      # 18 values plus the documented signature/response errors used by 3.8.
      # https://ai.google.dev/api/generate-content#FinishReason (2026-10-05)
      FINISH_REASONS = %w[
        FINISH_REASON_UNSPECIFIED STOP MAX_TOKENS SAFETY RECITATION LANGUAGE
        OTHER BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL
        IMAGE_SAFETY UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS
        IMAGE_PROHIBITED_CONTENT NO_IMAGE IMAGE_RECITATION IMAGE_OTHER
        MISSING_THOUGHT_SIGNATURE MALFORMED_RESPONSE
      ].freeze

      # The frozen 8-value BlockedReason enum (python-genai types.BlockedReason)
      # a promptFeedback.blockReason is judged against. A blocked prompt is a
      # complete answer, not an interrupted stream: Google returns no
      # candidate by design, and usageMetadata may still carry billable prompt
      # work. Its typed finish is PROMPT_<blockReason> — a prompt's SAFETY is
      # not a candidate's — and its word rides Result#refusal as the category.
      BLOCK_REASONS = %w[
        BLOCKED_REASON_UNSPECIFIED SAFETY OTHER BLOCKLIST PROHIBITED_CONTENT
        IMAGE_SAFETY MODEL_ARMOR JAILBREAK
      ].freeze
      PROMPT_BLOCK_PREFIX = "PROMPT_".freeze

      # The frozen 3.x reasoning vocabulary: reasoning_effort maps 1:1 onto
      # thinkingConfig.thinkingLevel (register "Reasoning contracts v1").
      # Everything outside it — including "none" (no disable level exists on
      # 3.x) — is a loud local rejection, never a nearest-level guess.
      # This is the WIRE GATE — the gemini registry row's
      # `reasoning_options` efforts are the other fact with the other job
      # (the reviewed per-lane catalog subset offered at selection), which
      # may narrow this set but never exceed it (pinned by
      # test_reasoning_wire_gates).
      THINKING_LEVELS = %w[minimal low medium high].freeze

      # Register-frozen local rejections for this lane: Google marks explicit
      # temperature/topP/topK deprecated/ignored on gemini-3.6-flash, and the
      # candidateCount surface (:n) is removed. The keys stay DECLARED in
      # request_option_keys so the rejection is this register-citing error,
      # not the generic unknown-option pointer at the extra_body escape hatch.
      LOCALLY_REJECTED_OPTIONS = %i[temperature top_p top_k n].freeze

      # usageMetadata modality rows with a canonical input subcount; other
      # modalities (VIDEO/DOCUMENT) stay bounded evidence only.
      MODALITY_INPUT_TOKEN_KEYS = { "IMAGE" => "image_input_tokens", "AUDIO" => "audio_input_tokens" }.freeze

      # Native usageMetadata fields retained VERBATIM as bounded evidence
      # (never promoted to canonical quantities, never dropped).
      BOUNDED_USAGE_EVIDENCE_KEYS = %w[
        promptTokensDetails candidatesTokensDetails toolUsePromptTokenCount
        toolUsePromptTokensDetails serviceTier trafficType
      ].freeze

      # The responses-family options this protocol maps onto generateContent
      # wire fields; Gemini-only wire fields ride extra_body. :thinking_config
      # takes a raw thinkingConfig hash verbatim (the camelCase symbol spelling
      # is NOT an option — as a wire field it belongs in extra_body).
      # seed/response_format map INTO generationConfig (their real wire home:
      # seed / responseMimeType+responseJsonSchema). temperature/top_p/top_k/n
      # remain declared vocabulary but are LOCALLY_REJECTED_OPTIONS (above).
      def self.request_option_keys
        %i[
          tools tool_choice instructions
          max_output_tokens temperature top_p top_k
          reasoning_enabled reasoning_effort thinking_config
          seed n response_format
        ].freeze
      end

      def create(model:, input:, **options)
        compile_create(model: model, input: input, **options).execute(config)
      end

      def compile_create(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        reject_locally_rejected_options(declared)
        body = finalize_wire_body(build_request_body(input: input, declared: declared), extra_body)

        compile_json_request(path: generate_content_path(model), body: body, stream: false) do |connection_config, compiled|
          gemini_result_from_response(compiled_response(compiled, config: connection_config))
        end
      end

      def compile_stream(model:, input:, **options)
        raise SimpleInference::ValidationError, "model is required" if model.nil? || model.to_s.strip.empty?

        declared, extra_body = split_request_options(options)
        reject_locally_rejected_options(declared)
        body = finalize_wire_body(build_request_body(input: input, declared: declared), extra_body)

        compile_json_request(path: stream_generate_content_path(model), body: body, stream: true) do |connection_config, compiled|
          stream_from_compiled(connection_config, compiled)
        end
      end

      def stream(model:, input:, **options)
        compile_stream(model: model, input: input, **options).execute(config)
      end

      def stream_from_compiled(connection_config, compiled)
        SimpleInference::Responses::Stream.new do |&emit|
          streamed_tool_call_arguments = {}
          emitted_tool_call_done = {}

          result =
            stream_result(connection_config: connection_config, compiled: compiled) do |delta, reasoning_delta, reasoning_item_id, output_items|
              unless delta.empty?
                emit.call(
                  SimpleInference::Responses::Events::TextDelta.new(
                    delta: delta
                  )
                )
              end

              unless reasoning_delta.empty?
                emit.call(
                  SimpleInference::Responses::Events::ReasoningDelta.new(
                    delta: reasoning_delta,
                    kind: "thought",
                    item_id: reasoning_item_id
                  )
                )
              end

              emit_stream_tool_call_events(
                emit: emit,
                output_items: output_items,
                streamed_tool_call_arguments: streamed_tool_call_arguments,
                emitted_done: emitted_tool_call_done,
                done: false
              )
            end

          emit_stream_tool_call_events(
            emit: emit,
            output_items: result.output_items,
            streamed_tool_call_arguments: streamed_tool_call_arguments,
            emitted_done: emitted_tool_call_done,
            done: true
          )
          emit.call(SimpleInference::Responses::Events::Completed.new(result: result))
          result
        end
      end

      private

      def gemini_result_from_response(response)
        body = response.body || {}
        block_reason = validated_block_reason(normalized_prompt_feedback(body["promptFeedback"]))
        unless block_reason.nil?
          return prompt_blocked_result(
            block_reason, id: body["responseId"] || body["id"], usage_metadata: body["usageMetadata"], response:
          )
        end

        candidate = Array(body["candidates"]).first || {}
        parts = candidate.dig("content", "parts")
        output_items = normalize_output_items(parts)
        finish_reason = validate_finish_reason(candidate["finishReason"])

        SimpleInference::Responses::Result.new(
          id: body["responseId"] || body["id"],
          output_text: extract_text(parts),
          output_items: output_items,
          tool_calls: SimpleInference::Responses::Result.tool_calls_from_output_items(output_items),
          usage: normalize_usage(body["usageMetadata"]),
          finish_reason: finish_reason,
          finish_detail: finish_reason,
          refusal: candidate_refusal(finish_reason),
          provider_response: response,
          provider_format: "responses"
        )
      end

      def stream_result(connection_config:, compiled:)
        full = +""
        reasoning_full = +""
        last_body = nil
        fold = StreamFold.new

        response =
          compiled_stream_response(compiled, config: connection_config) do |_event_name, body|
            last_body = body
            observe_stream_terminal(fold, body)
            observe_stream_result(fold, body)

            parts = Array(body.dig("candidates", 0, "content", "parts"))
            snapshot_text = extract_text(parts)
            delta = incremental_delta(snapshot_text, full)
            full << delta unless delta.empty?
            snapshot_reasoning = extract_thought_text(parts)
            reasoning_delta = incremental_delta(snapshot_reasoning, reasoning_full)
            reasoning_full << reasoning_delta unless reasoning_delta.empty?

            if block_given?
              yield(
                delta,
                reasoning_delta,
                extract_thought_signature(parts),
                fold.output_items
              )
            end
          end

        json_fallback = !response.body.nil?
        response_body = response.body || last_body || {}
        response = response.with(body: response_body) if response.body.nil? && !response_body.empty?

        # On the SSE path the block above already folded every chunk into
        # output_items (last_body IS the final chunk) — folding it again
        # would double incremental-mode text. Only the JSON fallback (the
        # gateway ignored Accept and returned one plain body; no SSE events
        # fired) still needs its parts extracted here.
        if json_fallback
          parts = Array(response_body.dig("candidates", 0, "content", "parts"))
          observe_stream_result(fold, response_body)
          full = extract_text(parts) if full.empty?
          observe_stream_terminal(fold, response_body, count_event: false)
        end

        block_reason = validated_block_reason(fold.prompt_feedback)
        unless block_reason.nil?
          return prompt_blocked_result(
            block_reason,
            id: response_body["responseId"] || response_body["id"],
            usage_metadata: fold.latest_usage_metadata, response:
          )
        end

        validate_stream_terminal(fold)

        SimpleInference::Responses::Result.new(
          id: response_body["responseId"] || response_body["id"],
          output_text: full,
          output_items: fold.output_items,
          tool_calls: SimpleInference::Responses::Result.tool_calls_from_output_items(fold.output_items),
          usage: normalize_usage(fold.latest_usage_metadata),
          finish_reason: fold.finish_reason,
          finish_detail: fold.finish_reason,
          refusal: candidate_refusal(fold.finish_reason),
          provider_response: response,
          provider_format: "responses"
        )
      end

      def observe_stream_result(fold, body)
        parts = Array(body.dig("candidates", 0, "content", "parts"))
        fold.output_items = merge_output_items(fold.output_items, normalize_output_items(parts))
        fold.latest_usage_metadata = body["usageMetadata"] if body["usageMetadata"]
        fold.prompt_feedback = normalized_prompt_feedback(body["promptFeedback"]) if body.key?("promptFeedback")
        fold
      end

      # A candidate's SAFETY-class or content-protection stop: Google's word
      # IS the category, and it sends no sentence.
      def candidate_refusal(finish_reason)
        SimpleInference::Responses::Refusal.for_finish(FinishQuality::GEMINI, finish_reason, category: finish_reason)
      end

      # The block reason, judged against the frozen enum; nil when the
      # prompt was not blocked.
      def validated_block_reason(prompt_feedback)
        reason = prompt_feedback["blockReason"].to_s
        return nil if reason.empty?
        return reason if BLOCK_REASONS.include?(reason)

        raise UnknownFinishReasonError,
              "gemini returned promptFeedback.blockReason #{reason.inspect}, which is outside the frozen " \
              "8-value released-SDK BlockedReason enum — refusing to classify an unknown terminal"
      end

      # No candidate exists, so no finishReason either: the typed detail
      # carries the block, and the Result carries no answer.
      def prompt_blocked_result(block_reason, id:, usage_metadata:, response:)
        finish_detail = "#{PROMPT_BLOCK_PREFIX}#{block_reason}"

        SimpleInference::Responses::Result.new(
          id: id,
          output_text: "",
          output_items: [],
          tool_calls: [],
          usage: normalize_usage(usage_metadata),
          finish_reason: nil,
          finish_detail: finish_detail,
          refusal: SimpleInference::Responses::Refusal.for_finish(FinishQuality::GEMINI, finish_detail, category: block_reason),
          provider_response: response,
          provider_format: "responses"
        )
      end

      def normalized_prompt_feedback(value)
        Internal::Keys.shallow_stringify(value)
      end

      def observe_stream_terminal(fold, body, count_event: true)
        fold.count_event if count_event
        finish_reason = chunk_finish_reason(body)
        fold.finish_reason = finish_reason unless finish_reason.nil?
      end

      # Terminal recognition is explicit: a stream (or JSON fallback body)
      # that never carried a finishReason on any candidate is an
      # INTERRUPTION, never a silent normal Result.
      def validate_stream_terminal(fold)
        return unless fold.finish_reason.nil?

        raise InterruptedStreamError.new(
          "the gemini stream ended without a terminal chunk (no finishReason on any candidate) — " \
          "the response is an interruption, not a completed result",
          events_seen: fold.events_seen,
        )
      end

      # The first finishReason any candidate of this chunk carries, validated
      # against the frozen enum (fail closed on unknown terminal vocabulary).
      def chunk_finish_reason(body)
        reason = Array(body["candidates"]).filter_map { |candidate| candidate["finishReason"] }.first
        validate_finish_reason(reason)
      end

      def validate_finish_reason(reason)
        return nil if reason.nil?
        return reason if FINISH_REASONS.include?(reason)

        raise UnknownFinishReasonError,
              "gemini returned finishReason #{reason.inspect}, which is outside the supported " \
              "FinishReason enum — refusing to classify an unknown terminal"
      end

      # Register-frozen local rejections (zero outbound IO): explicit
      # temperature/topP/topK are deprecated/ignored by Google on
      # gemini-3.6-flash, and the :n -> candidateCount surface is removed.
      def reject_locally_rejected_options(declared)
        rejected = LOCALLY_REJECTED_OPTIONS.select { |key| declared.key?(key) }
        return if rejected.empty?

        raise SimpleInference::ValidationError,
              "request option(s) #{rejected.join(", ")} are locally rejected for gemini generateContent: " \
              "Google marks explicit temperature/topP/topK deprecated-ignored and no candidateCount " \
              "surface exists on this lane (frozen conformance-register disposition) — remove the option(s)"
      end

      # Deterministic path constructions: the model rides in the path segment,
      # and the SSE variant is a different endpoint carrying alt=sse.
      def generate_content_path(model)
        "/v1beta/models/#{model}:generateContent"
      end

      def stream_generate_content_path(model)
        "/v1beta/models/#{model}:streamGenerateContent?alt=sse"
      end

      def gemini_headers(connection_config)
        headers = connection_config.headers.reject { |key, _value| key.to_s.casecmp("authorization").zero? }
        return headers if connection_config.api_key.nil?

        # No api_key means NO credential header — never an empty "x-goog-api-key".
        headers.merge("x-goog-api-key" => connection_config.api_key)
      end

      def compiled_connection_headers(connection_config)
        gemini_headers(connection_config)
      end

      def incremental_delta(snapshot_text, accumulated_text)
        snapshot = snapshot_text.to_s
        return "" if snapshot.empty?
        return snapshot unless snapshot.start_with?(accumulated_text)

        snapshot.delete_prefix(accumulated_text)
      end

      def incremental_argument_delta(current_arguments, previous_arguments)
        current = current_arguments.to_s
        previous = previous_arguments.to_s
        return "" if current.empty?
        return current if previous.empty?
        return current.delete_prefix(previous) if current.start_with?(previous)

        prefix_length = 0
        limit = [current.length, previous.length].min
        while prefix_length < limit && current.getbyte(prefix_length) == previous.getbyte(prefix_length)
          prefix_length += 1
        end

        delta = current.byteslice(prefix_length..)
        delta.to_s.empty? ? current : delta.to_s
      end

      def merge_output_items(existing_items, incoming_items)
        merged = existing_items

        # Indices an incoming item of THIS batch already appended or merged
        # into. Gemini emits parallel calls to the same function as sibling
        # parts of one chunk (often without ids); without this claim set the
        # id-less name fallback would collapse two distinct same-name calls.
        claimed = []

        coalesce_text_items(Array(incoming_items)).each do |item|
          item_type = item["type"].to_s

          unless item_type == "function_call"
            index =
              if %w[message reasoning].include?(item_type)
                merged.find_index { |candidate| candidate["type"].to_s == item_type }
              end

            if index
              merged[index] = accumulate_text_item(merged[index], item)
            else
              merged << item
            end
            next
          end

          index =
            merged.find_index do |candidate|
              next false unless candidate["type"].to_s == "function_call"

              same_id = candidate["id"].to_s != "" && candidate["id"].to_s == item["id"].to_s
              same_call_id = candidate["call_id"].to_s != "" && candidate["call_id"].to_s == item["call_id"].to_s
              same_id || same_call_id
            end
          index ||= name_fallback_merge_index(merged, item, claimed)

          if index
            merged[index] = merged[index].merge(item)
            claimed << index
          else
            merged << item
            claimed << merged.length - 1
          end
        end

        merged
      end

      # Join a batch's sibling message parts (and reasoning parts) into ONE
      # item per type BEFORE the cross-chunk fold — the same granularity
      # stream_result uses for output_text (extract_text joins the chunk's
      # parts, THEN computes one delta). Folding part-by-part would delta
      # each sibling against text the previous sibling just added, so a
      # repeated or prefix-shaped sibling ("ha","ha") would read as a
      # cumulative resend and get swallowed from the persisted item.
      def coalesce_text_items(items)
        first_index = {}
        coalesced = []

        items.each do |item|
          type = item["type"].to_s

          unless %w[message reasoning].include?(type)
            coalesced << item
            next
          end

          index = first_index[type]
          if index
            coalesced[index] = join_sibling_text_items(coalesced[index], item)
          else
            first_index[type] = coalesced.length
            coalesced << item
          end
        end

        coalesced
      end

      # Sibling parts of one chunk are distinct fragments by definition —
      # plain concatenation, exactly like extract_text's join.
      def join_sibling_text_items(existing, incoming)
        if existing["type"].to_s == "message"
          combined = message_item_text(existing) + message_item_text(incoming)
          existing.merge("content" => [{ "type" => "output_text", "text" => combined }])
        else
          combined = existing["text"].to_s + incoming["text"].to_s
          existing.merge(incoming).merge("text" => combined)
        end
      end

      # Gemini streams text in TWO shapes: cumulative snapshot resends (each
      # chunk carries the full text so far) and incremental fragments (each
      # chunk carries only new text — the current default). Folding every
      # chunk into ONE message/reasoning item via incremental_delta handles
      # both: a snapshot contributes only its unseen suffix, a fragment
      # appends whole — so the persisted item text stays identical to the
      # accumulated output_text (the kernel replays output_items as trace).
      # A per-chunk field like thoughtSignature keeps last-writer-wins.
      def accumulate_text_item(existing, incoming)
        if existing["type"].to_s == "message"
          existing_text = message_item_text(existing)
          combined = existing_text + incremental_delta(message_item_text(incoming), existing_text)
          existing.merge("content" => [{ "type" => "output_text", "text" => combined }])
        else
          existing_text = existing["text"].to_s
          combined = existing_text + incremental_delta(incoming["text"].to_s, existing_text)
          existing.merge(incoming).merge("text" => combined)
        end
      end

      def message_item_text(item)
        Array(item["content"]).filter_map { |part| part["text"] }.join
      end

      # The id-less merge fallback: Gemini's cumulative streaming re-sends a
      # call's complete part in later chunks without ids, so a same-name
      # candidate with compatible arguments (identical, or a not-yet-argued
      # accumulator) is the same call. A candidate this batch already claimed
      # is never a target — that keeps distinct parallel same-name calls apart.
      def name_fallback_merge_index(merged, item, claimed)
        merged.each_with_index do |candidate, candidate_index|
          next if claimed.include?(candidate_index)
          next unless candidate["type"].to_s == "function_call"
          next if candidate["name"].to_s == "" || candidate["name"].to_s != item["name"].to_s

          candidate_arguments = candidate["arguments"].to_s
          compatible = candidate_arguments.empty? ||
                       candidate_arguments == "{}" ||
                       candidate_arguments == item["arguments"].to_s
          return candidate_index if compatible
        end

        nil
      end

      def emit_stream_tool_call_events(emit:, output_items:, streamed_tool_call_arguments:, emitted_done:, done:)
        tool_calls = Array(output_items).filter_map do |item|
          Internal::Keys.shallow_stringify(item) if item["type"].to_s == "function_call"
        end

        tool_calls.each_with_index do |item, index|
          item_id = item["id"] || item["call_id"] || "tool_call_#{index}"
          arguments = item["arguments"].to_s
          previous_arguments = streamed_tool_call_arguments[item_id].to_s
          delta = incremental_argument_delta(arguments, previous_arguments)

          unless delta.empty?
            emit.call(
              SimpleInference::Responses::Events::ToolCallDelta.new(
                item_id: item_id,
                call_id: item["call_id"] || item["id"],
                name: item["name"],
                delta: delta
              )
            )
          end

          streamed_tool_call_arguments[item_id] = arguments
          next unless done
          next if emitted_done[item_id]

          emit.call(
            SimpleInference::Responses::Events::ToolCallDone.new(
              item_id: item_id,
              call_id: item["call_id"] || item["id"],
              name: item["name"],
              arguments: arguments
            )
          )
          emitted_done[item_id] = true
        end
      end

      def normalize_output_items(parts)
        Array(parts).filter_map do |part|
          normalized = Internal::Keys.shallow_stringify(part)
          function_call = normalized["functionCall"]

          if function_call
            normalized_call = Internal::Keys.shallow_stringify(function_call)
            provider_payload = { "functionCall" => normalized_call }
            thought_signature = thought_signature_of(normalized)
            provider_payload["thoughtSignature"] = thought_signature if thought_signature

            {
              "type" => "function_call",
              "id" => normalized_call["id"],
              "call_id" => normalized_call["id"],
              "name" => normalized_call["name"],
              "arguments" => JSON.generate(normalized_call["args"] || {}),
              "provider_payload" => provider_payload,
            }.compact
          elsif thought_part?(normalized)
            {
              "type" => "reasoning",
              "text" => normalized["text"].to_s,
              "signature" => thought_signature_of(normalized),
              "provider_payload" => normalized,
            }.compact
          elsif normalized["text"]
            {
              "type" => "message",
              "content" => [
                {
                  "type" => "output_text",
                  "text" => normalized["text"].to_s,
                },
              ],
            }
          end
        end
      end

      def extract_text(parts)
        Array(parts).filter_map do |part|
          normalized = Internal::Keys.shallow_stringify(part)
          next if thought_part?(normalized)

          normalized["text"]
        end.join
      end

      def extract_thought_text(parts)
        Array(parts).filter_map do |part|
          normalized = Internal::Keys.shallow_stringify(part)
          next unless thought_part?(normalized)

          normalized["text"]
        end.join
      end

      def extract_thought_signature(parts)
        Array(parts).filter_map do |part|
          normalized = Internal::Keys.shallow_stringify(part)
          next unless thought_part?(normalized)

          thought_signature_of(normalized)
        end.first
      end

      def thought_part?(part)
        part["thought"] == true || part["thought"].to_s == "true"
      end

      # The ONE accessor that knows both signature spellings: Gemini emits
      # camelCase "thoughtSignature" on the wire, but replayed history may
      # carry the snake_case spelling. Callers pass a string-keyed hash.
      def thought_signature_of(hash)
        hash["thoughtSignature"] || hash["thought_signature"]
      end

      # Truthful parsing per the frozen usage matrix: canonical quantities are
      # normalized, IMAGE/AUDIO modality rows promote to their canonical input
      # subcounts, and modality-detail rows/serviceTier/tool-use counts are
      # RETAINED verbatim as bounded native evidence instead of being dropped.
      # Presence-vs-zero is preserved throughout — a field absent on the wire
      # stays absent, never a fabricated 0.
      def normalize_usage(usage_metadata)
        return nil if usage_metadata.nil?

        usage = {
          "input_tokens" => canonical_usage_count(usage_metadata["promptTokenCount"]),
          "cache_read_input_tokens" => canonical_usage_count(usage_metadata["cachedContentTokenCount"]),
          "output_tokens" => inclusive_output_tokens(usage_metadata),
          "reasoning_tokens" => canonical_usage_count(usage_metadata["thoughtsTokenCount"]),
          "total_tokens" => canonical_usage_count(usage_metadata["totalTokenCount"]),
        }
        usage.merge!(modality_input_subcounts(usage_metadata["promptTokensDetails"]))
        usage.merge!(bounded_usage_evidence(usage_metadata))
        usage.compact
      end

      # IMAGE -> image_input_tokens, AUDIO -> audio_input_tokens (closed
      # promotion map); rows whose tokenCount is absent on the wire promote
      # nothing (presence-vs-zero), and other modalities stay evidence-only.
      def modality_input_subcounts(prompt_tokens_details)
        Array(prompt_tokens_details).each_with_object({}) do |row, subcounts|
          canonical_key = MODALITY_INPUT_TOKEN_KEYS[row["modality"].to_s]
          next if canonical_key.nil?
          count = canonical_usage_count(row["tokenCount"])
          subcounts[canonical_key] = count unless count.nil?
        end
      end

      def bounded_usage_evidence(usage_metadata)
        BOUNDED_USAGE_EVIDENCE_KEYS.each_with_object({}) do |key, evidence|
          evidence[key] = usage_metadata[key] if usage_metadata.key?(key)
        end
      end

      # The responses-family output_tokens is reasoning-INCLUSIVE (OpenAI
      # semantics), but Gemini's candidatesTokenCount EXCLUDES thoughts; the
      # reference sums candidates + thoughts for inclusive output. Billing on
      # the raw candidate count would under-bill thinking output.
      #
      # Presence discipline (register `gemini_generate_content.usage.v1`):
      # an ABSENT candidatesTokenCount keeps output_tokens absent — thoughts
      # alone never fabricate an output count. When a summand IS on the wire
      # it contributes only when it is a nonnegative Integer. Auxiliary usage
      # is accounting evidence: a malformed member is absent from canonical
      # usage and never invalidates an otherwise valid provider answer.
      def inclusive_output_tokens(usage_metadata)
        candidates_tokens = canonical_usage_count(usage_metadata["candidatesTokenCount"])
        return nil if candidates_tokens.nil?

        thoughts_tokens = canonical_usage_count(usage_metadata["thoughtsTokenCount"])
        return candidates_tokens if thoughts_tokens.nil?

        candidates_tokens + thoughts_tokens
      end

      def canonical_usage_count(value)
        case value
        when Integer
          value unless value.negative?
        else
          nil
        end
      end

      # A tool's output is the wire's JSON object text, an already-structured
      # Hash, or plain text the reference client wraps as {"result"}.
      def normalize_function_response(value)
        case value
        when Hash then value
        else parse_json_object(value.to_s)
        end
      rescue SimpleInference::DecodeError
        { "result" => value.to_s }
      end

      # Arguments arrive as the wire's JSON text or an already-parsed Hash.
      def parse_arguments(value)
        case value
        when Hash then value
        when nil, "" then {}
        else JSON.parse(value.to_s)
        end
      rescue JSON::ParserError
        {}
      end

      def stringify_content(value)
        case value
        when String
          value
        when Hash, Array
          JSON.generate(value)
        else
          value.to_s
        end
      end
    end
  end
end
