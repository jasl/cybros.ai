require "json"
require "test_helper"

class TestGeminiProtocol < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  def test_create_maps_generate_content_payload_into_responses_result
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { thoughtSignature: "sig_123", functionCall: { id: "call_123", name: "calculator", args: { expression: "2 + 2" } } },
                      { text: "Gemini hello" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
              usageMetadata: {
                promptTokenCount: 2,
                candidatesTokenCount: 3,
                totalTokenCount: 5,
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    result = protocol.create(
      model: "gemini-3.5-flash",
      input: [
        { role: "system", content: "Be terse" },
        { role: "user", content: "Hello" },
        {
          type: "function_call",
          call_id: "call_123",
          name: "calculator",
          arguments: "{\"expression\":\"2 + 2\"}",
          provider_payload: {
            functionCall: {
              id: "call_123",
              name: "calculator",
              args: {
                expression: "2 + 2",
              },
            },
            thoughtSignature: "sig_123",
          },
        },
        {
          type: "function_call_output",
          call_id: "call_123",
          name: "calculator",
          output: "{\"value\":4}",
        },
      ],
      tools: [
        {
          type: "function",
          name: "calculator",
          description: "Solve arithmetic",
          parameters: {
            type: "object",
            properties: {
              expression: { type: "string" },
            },
          },
        },
        {
          type: "function",
          function: {
            name: "calculator",
            description: "Solve arithmetic again",
            parameters: {
              type: "object",
              properties: {
                expression: { type: "string" },
              },
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_instance_of SimpleInference::Responses::Result, result
    assert_equal "Gemini hello", result.output_text
    assert_equal 5, result.usage.fetch("total_tokens")
    assert_equal "responses", result.provider_format
    assert_equal "function_call", result.output_items.fetch(0).fetch("type")
    assert_equal "calculator", result.tool_calls.fetch(0).fetch("name")
    assert_equal "sig_123", result.output_items.fetch(0).fetch("provider_payload").fetch("thoughtSignature")
    assert_equal "Be terse", request_body.fetch("systemInstruction").fetch("parts").fetch(0).fetch("text")
    assert_equal "Hello", request_body.fetch("contents").fetch(0).fetch("parts").fetch(0).fetch("text")
    assert_equal "sig_123", request_body.fetch("contents").fetch(1).fetch("parts").fetch(0).fetch("thoughtSignature")
    assert_equal "calculator", request_body.fetch("contents").fetch(2).fetch("parts").fetch(0).fetch("functionResponse").fetch("name")
    assert_equal 2, request_body.fetch("tools").fetch(0).fetch("functionDeclarations").length
  end

  def test_create_maps_thought_parts_to_reasoning_items_and_excludes_them_from_output_text
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { thought: true, thoughtSignature: "sig_thought", text: "Need a short answer." },
                      { text: "Final answer" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
              usageMetadata: {
                promptTokenCount: 2,
                cachedContentTokenCount: 1,
                thoughtsTokenCount: 4,
                candidatesTokenCount: 3,
                totalTokenCount: 9,
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    result = protocol.create(model: "gemini-3.5-flash", input: "Hello", reasoning_effort: "medium")
    request_body = JSON.parse(adapter.last_request.fetch(:body))
    reasoning_item = result.output_items.find { |item| item["type"] == "reasoning" }

    # Frozen reasoning contract: 3.x reasoning rides thinkingLevel, never the
    # 2.5-era thinkingBudget.
    assert_equal({ "includeThoughts" => true, "thinkingLevel" => "medium" }, request_body.dig("generationConfig", "thinkingConfig"))
    assert_equal "Final answer", result.output_text
    assert_equal "Need a short answer.", reasoning_item.fetch("text")
    assert_equal "sig_thought", reasoning_item.fetch("signature")
    assert_equal 1, result.usage.fetch("cache_read_input_tokens")
    assert_equal 4, result.usage.fetch("reasoning_tokens")
    # output_tokens is reasoning-INCLUSIVE (OpenAI semantics): Gemini's
    # candidatesTokenCount excludes thoughts, so 3 candidates + 4 thoughts = 7.
    assert_equal 7, result.usage.fetch("output_tokens")
  end

  # --- usage presence-vs-zero and non-coercion (C3) ---
  # An ABSENT candidatesTokenCount keeps output_tokens absent: thoughts alone
  # never fabricate an output count. A summand that IS on the wire contributes
  # only when it is a nonnegative Integer. Bad accounting metadata is omitted
  # from canonical usage; it never discards an otherwise valid answer.

  def test_absent_candidates_token_count_keeps_output_tokens_absent_even_with_thoughts
    adapter = usage_metadata_adapter(promptTokenCount: 2, thoughtsTokenCount: 4, totalTokenCount: 6)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    refute result.usage.key?("output_tokens"),
           "thoughtsTokenCount alone must never fabricate output_tokens"
    assert_equal 4, result.usage.fetch("reasoning_tokens")
  end

  def test_non_integer_candidates_token_count_is_omitted_without_discarding_output
    adapter = usage_metadata_adapter(promptTokenCount: 2, candidatesTokenCount: "3", totalTokenCount: 5)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    assert_equal "ok", result.output_text
    assert_equal 2, result.usage.fetch("input_tokens")
    assert_equal 5, result.usage.fetch("total_tokens")
    refute result.usage.key?("output_tokens")
    assert_equal "3", result.provider_response.body.dig("usageMetadata", "candidatesTokenCount")
  end

  def test_non_integer_thoughts_token_count_is_omitted_without_discarding_output
    adapter = usage_metadata_adapter(promptTokenCount: 2, candidatesTokenCount: 3, thoughtsTokenCount: "4", totalTokenCount: 9)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    assert_equal "ok", result.output_text
    assert_equal 3, result.usage.fetch("output_tokens"),
                 "the valid candidate count survives a bad auxiliary thoughts count"
    refute result.usage.key?("reasoning_tokens")
    assert_equal "4", result.provider_response.body.dig("usageMetadata", "thoughtsTokenCount")
  end

  def test_stream_bad_auxiliary_usage_still_completes_with_provider_output
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          payload = {
            candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
            usageMetadata: {
              promptTokenCount: 2,
              candidatesTokenCount: 3,
              thoughtsTokenCount: "bad",
              totalTokenCount: 5,
            },
          }
          yield "data: #{JSON.generate(payload)}\n\n"
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    result = gemini_protocol(adapter: adapter)
             .stream(model: "gemini-3.5-flash", input: "Hello")
             .final_result

    assert_equal "ok", result.output_text
    assert_equal 3, result.usage.fetch("output_tokens")
    refute result.usage.key?("reasoning_tokens")
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): provider requests
  # embed prepared bytes inline; caller data URIs, URLs, host paths, and
  # provider file handles are loud rejections at the lane's lowering.

  def test_media_input_bytes_lower_to_the_inline_data_wire_form
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = capturing_gemini_adapter
    protocol = gemini_protocol(adapter: adapter)

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        {
          role: "user",
          content: [
            { "type" => "input_text", "text" => "look" },
            { "type" => "input_image", "image_url" => media },
          ],
        },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    inline = body.fetch("contents").fetch(0).fetch("parts").find { |part| part.key?("inline_data") }.fetch("inline_data")
    assert_equal "image/png", inline.fetch("mime_type")
    assert_equal [PNG_BYTES].pack("m0"), inline.fetch("data")
  end

  def test_caller_data_uri_image_is_a_loud_rejection
    protocol = gemini_protocol(adapter: exploding_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "gemini-3.7-flash",
          input: [{ role: "user", content: [{ "type" => "input_image", "image_url" => "data:image/png;base64,AAAA" }] }]
        )
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_image_is_a_loud_rejection
    protocol = gemini_protocol(adapter: exploding_adapter)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "gemini-3.7-flash",
        input: [{ role: "user", content: [{ "type" => "input_image", "image_url" => { "url" => "https://example.com/cat.png" } }] }]
      )
    end
  end

  def test_stream_uses_stream_generate_content_sse_and_emits_text_and_tool_call_events
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(_env)
          raise "stream should use call_stream"
        end

        def call_stream(env)
          @last_request = env

          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hel" }, { functionCall: { id: "call_123", name: "calculator", args: { expression: "2 +" } } }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hello" }, { functionCall: { id: "call_123", name: "calculator", args: { expression: "2 + 2" } } }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 3, totalTokenCount: 5 } })}\n\n"

          yield sse

          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "gemini-3.5-flash", input: "Hello").to_a

    assert_includes adapter.last_request.fetch(:url), ":streamGenerateContent?alt=sse"
    text_deltas = events.grep(SimpleInference::Responses::Events::TextDelta).map(&:delta)
    tool_delta = events.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDelta) }
    tool_done = events.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDone) }
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }

    assert_equal ["Hel", "lo"], text_deltas
    refute_nil tool_delta
    refute_nil tool_done
    assert_equal "call_123", tool_delta.call_id
    assert_equal "calculator", tool_delta.name
    assert_equal "{\"expression\":\"2 +\"}", tool_delta.delta
    assert_equal "{\"expression\":\"2 + 2\"}", tool_done.arguments
    refute_nil completed
    assert_equal "Hello", completed.result.output_text
    assert_equal "calculator", completed.result.tool_calls.fetch(0).fetch("name")
    assert_equal 5, completed.result.usage.fetch("total_tokens")
  end

  def test_stream_yields_thought_parts_as_reasoning_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ thought: true, text: "Need " }, { text: "Hel" }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ thought: true, thoughtSignature: "sig_123", text: "Need tool." }, { text: "Hello" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 2, thoughtsTokenCount: 4, candidatesTokenCount: 3, totalTokenCount: 9 } })}\n\n"

          yield sse

          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "gemini-3.5-flash", input: "Hello", reasoning_effort: "medium").to_a

    text_deltas = events.grep(SimpleInference::Responses::Events::TextDelta).map(&:delta)
    reasoning_deltas = events.grep(SimpleInference::Responses::Events::ReasoningDelta).map(&:delta)
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    reasoning_item = completed.result.output_items.find { |item| item["type"] == "reasoning" }

    assert_equal ["Hel", "lo"], text_deltas
    assert_equal ["Need ", "tool."], reasoning_deltas
    assert_equal "Hello", completed.result.output_text
    assert_equal "Need tool.", reasoning_item.fetch("text")
    assert_equal "sig_123", reasoning_item.fetch("signature")
    assert_equal 4, completed.result.usage.fetch("reasoning_tokens")
    assert_equal 7, completed.result.usage.fetch("output_tokens")
  end

  # Gemini's CURRENT streaming default sends INCREMENTAL fragments (each
  # chunk carries only new text), unlike the cumulative snapshot resends the
  # two tests above pin. The final Result's message/reasoning items must
  # accumulate across fragments and stay consistent with output_text — the
  # kernel persists output_items as the conversation trace, so a
  # last-fragment-only item silently truncates replay history.
  def test_incremental_streaming_accumulates_message_and_reasoning_items
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ thought: true, text: "Plan " }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ thought: true, thoughtSignature: "sig_inc", text: "steps." }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hello " }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "world" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 2, thoughtsTokenCount: 4, candidatesTokenCount: 3, totalTokenCount: 9 } })}\n\n"

          yield sse

          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "gemini-3.5-flash", input: "Hello", reasoning_effort: "medium").to_a

    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    message_items = completed.result.output_items.select { |item| item["type"] == "message" }
    reasoning_items = completed.result.output_items.select { |item| item["type"] == "reasoning" }

    assert_equal ["Hello ", "world"], events.grep(SimpleInference::Responses::Events::TextDelta).map(&:delta)
    assert_equal ["Plan ", "steps."], events.grep(SimpleInference::Responses::Events::ReasoningDelta).map(&:delta)
    assert_equal "Hello world", completed.result.output_text

    assert_equal 1, message_items.length, "incremental fragments must fold into one message item"
    message_text = message_items.fetch(0).fetch("content").filter_map { |part| part["text"] }.join
    assert_equal completed.result.output_text, message_text,
                 "persisted message item must carry the SAME text as output_text (trace fidelity)"

    assert_equal 1, reasoning_items.length, "incremental fragments must fold into one reasoning item"
    assert_equal "Plan steps.", reasoning_items.fetch(0).fetch("text")
    assert_equal "sig_inc", reasoning_items.fetch(0).fetch("signature")
  end

  # Sibling text parts inside ONE chunk must fold at the same granularity as
  # output_text (which joins the chunk's parts BEFORE computing its delta).
  # Folding part-by-part would delta each sibling against text the previous
  # sibling just added — a repeated or prefix-shaped sibling ("ha","ha")
  # would read as a cumulative resend and get swallowed from the item.
  def test_sibling_text_parts_in_one_chunk_fold_without_prefix_swallowing
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "ha" }, { text: "ha" }] }, finishReason: "STOP" }] })}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    result = protocol.stream(model: "gemini-3.5-flash", input: "Hello").final_result

    assert_equal "haha", result.output_text
    message_text = result.output_items.select { |item| item["type"] == "message" }
                         .flat_map { |item| Array(item["content"]).filter_map { |part| part["text"] } }.join
    assert_equal result.output_text, message_text
  end

  # A cumulative-mode snapshot that re-splits its part boundaries relative to
  # earlier chunks ("AB" resent as ["A", "BC"]) must still fold as ONE
  # chunk-level snapshot — per-part folding would append both parts whole and
  # duplicate text the item already carries.
  def test_resplit_cumulative_snapshot_does_not_duplicate_message_item_text
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "AB" }] } }] })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "A" }, { text: "BC" }] }, finishReason: "STOP" }] })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    result = protocol.stream(model: "gemini-3.5-flash", input: "Hello").final_result

    assert_equal "ABC", result.output_text
    message_text = result.output_items.select { |item| item["type"] == "message" }
                         .flat_map { |item| Array(item["content"]).filter_map { |part| part["text"] } }.join
    assert_equal result.output_text, message_text
  end

  # Frozen reasoning contract (register "Reasoning contracts v1"): the gemini
  # lane's wire vocabulary is thinkingConfig.thinkingLevel ∈ minimal|low|
  # medium|high. Every accepted effort maps 1:1 onto that closed set.
  def test_create_maps_each_accepted_reasoning_effort_to_thinking_level
    %w[minimal low medium high].each do |effort|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      protocol.create(model: "gemini-3.7-flash", input: "Hello", reasoning_effort: effort)

      thinking_config = JSON.parse(adapter.last_request.fetch(:body)).dig("generationConfig", "thinkingConfig")
      assert_equal effort, thinking_config.fetch("thinkingLevel")
      assert_equal true, thinking_config.fetch("includeThoughts")
      refute thinking_config.key?("thinkingBudget"), "3.x reasoning must never emit the 2.5-era thinkingBudget"
    end
  end

  # Efforts outside the frozen 3.x thinkingLevel vocabulary (none, xhigh, max,
  # typos) are loud local rejections with zero outbound IO — there is no
  # thinkingBudget disable path and no silent nearest-level mapping.
  def test_create_rejects_reasoning_effort_outside_the_frozen_thinking_level_vocabulary
    %w[none xhigh max bogus].each do |effort|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "gemini-3.7-flash", input: "Hello", reasoning_effort: effort)
        end

      assert_includes error.message, effort
      assert_includes error.message, "thinkingLevel"
      assert_nil adapter.last_request, "a rejected reasoning_effort must produce zero outbound IO"
    end
  end

  def test_omitted_reasoning_effort_sends_no_thinking_config
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.7-flash", input: "Hello")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_nil body.dig("generationConfig", "thinkingConfig"), "the server-side default (medium) applies when unset"
  end

  # Register "All-workload request-control" frozen disposition: this lane
  # locally rejects explicit temperature/top_p/top_k — Google marks them
  # deprecated/ignored on gemini-3.7-flash, so Nexus never forwards a control
  # whose effect it cannot observe. Deterministic pre-wire rejection, zero IO.
  def test_create_locally_rejects_temperature_top_p_and_top_k_pre_wire
    { temperature: 0.3, top_p: 0.9, top_k: 40 }.each do |key, value|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "gemini-3.7-flash", input: "Hello", key => value)
        end

      assert_includes error.message, key.to_s
      assert_includes error.message, "locally rejected"
      assert_nil adapter.last_request, "#{key} must be rejected before any outbound IO"
    end
  end

  # The frozen register removes the candidateCount surface for this lane: :n
  # is a loud local rejection and no code path writes candidateCount.
  def test_create_locally_rejects_n_and_never_builds_candidate_count
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.7-flash", input: "Hello", n: 2)
      end

    assert_includes error.message, "n"
    assert_includes error.message, "locally rejected"
    assert_nil adapter.last_request
  end

  def test_stream_locally_rejects_sampling_controls_pre_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "gemini-3.7-flash", input: "Hello", temperature: 0.5)
      end

    assert_includes error.message, "temperature"
    assert_nil adapter.last_request
  end

  # Register disposition: reject input whose last nonempty turn is assistant
  # (wire "model") instead of dropping/relabeling/padding it.
  def test_create_rejects_assistant_last_input_pre_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "gemini-3.7-flash",
          input: [
            { role: "user", content: "Question" },
            { role: "assistant", content: "Half-finished answer" },
          ]
        )
      end

    assert_includes error.message, "assistant"
    assert_nil adapter.last_request, "assistant-last input must be rejected before any outbound IO"
  end

  def test_create_accepts_assistant_history_when_user_turn_is_last
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        { role: "user", content: "Question" },
        { role: "assistant", content: "Prior answer" },
        { role: "user", content: "Follow-up" },
      ]
    )

    roles = JSON.parse(adapter.last_request.fetch(:body)).fetch("contents").map { |content| content.fetch("role") }
    assert_equal %w[user model user], roles
  end

  # The Responses family's `developer` role has no twin on this wire: it
  # lowers to `user` and stays WHERE THE CALLER PLACED IT in the list —
  # hoisting it into systemInstruction would move it ahead of everything
  # behind it (Nexus S-F r2 (5)). A role outside the vocabulary is still
  # the loud pre-wire error, never a quiet "user" turn.
  def test_create_lowers_developer_to_user_in_place
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.7-flash",
      input: [
        { role: "user", content: "memory" }, { role: "developer", content: "env" },
        { role: "user", content: "Hi" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    content = body.fetch("contents").fetch(0)
    assert_equal 1, body.fetch("contents").length, "adjacent user turns merge, as this wire always did"
    assert_equal "user", content.fetch("role")
    assert_equal ["memory", "env", "Hi"], content.fetch("parts").map { |part| part.fetch("text") },
      "the developer text stays between memory and the prompt — lowered in place"
    refute body.key?("systemInstruction"), "lowered in place, never hoisted"
    # The kernel's admission reads ACCEPTED_ROLES, so the constant must name
    # what normalize_role admits: its Anthropic twin was caught parking every
    # developer-led conversation at turn 1 (the paid live_cache_tier lane on
    # the direct Anthropic lane, 2026-09-18); this wire had the same gap.
    assert_includes SimpleInference::Protocols::GeminiGenerateContent::ACCEPTED_ROLES, "developer"
  end

  def test_create_rejects_unknown_roles_loudly
    %w[banana].each do |role|
      adapter = capturing_gemini_adapter
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(
            model: "gemini-3.7-flash",
            input: [{ role: role, content: "Hello" }, { role: "user", content: "Hi" }]
          )
        end

      assert_includes error.message, role
      assert_nil adapter.last_request, "an unknown role (#{role}) must never silently reach the wire"
    end
  end

  def test_create_normalizes_gemini_tool_schema_and_tool_choice
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: { type: "function", function: { name: "calculator" } },
      tools: [
        {
          type: "function",
          function: {
            name: "calculator",
            description: "Solve arithmetic",
            parameters: {
              type: "object",
              properties: {
                expression: {
                  anyOf: [
                    { type: "string" },
                    { type: "null" },
                  ],
                  description: "Math expression",
                },
              },
              required: [:expression],
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    declaration = request_body.fetch("tools").fetch(0).fetch("functionDeclarations").fetch(0)
    schema = declaration.fetch("parameters")
    property = schema.fetch("properties").fetch("expression")
    tool_config = request_body.fetch("toolConfig").fetch("functionCallingConfig")

    assert_equal "OBJECT", schema.fetch("type")
    assert_equal ["expression"], schema.fetch("required")
    assert_equal "STRING", property.fetch("type")
    assert_equal true, property.fetch("nullable")
    assert_equal "Math expression", property.fetch("description")
    assert_equal "any", tool_config.fetch("mode")
    assert_equal ["calculator"], tool_config.fetch("allowedFunctionNames")
  end

  def test_create_omits_function_response_id_when_history_lacks_call_id
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: [
        { role: "user", content: "Add it up" },
        { type: "function_call", name: "calculator", arguments: "{\"expression\":\"2 + 2\"}" },
        { type: "function_call_output", name: "calculator", output: "{\"value\":4}" },
        { role: "tool", name: "calculator", content: "{\"value\":4}" },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    function_responses = request_body.fetch("contents").flat_map { |content| content.fetch("parts") }.filter_map { |part| part["functionResponse"] }

    assert_equal 2, function_responses.length
    function_responses.each do |function_response|
      assert_equal "calculator", function_response.fetch("name")
      # The reference client omits the id key entirely when there is no call
      # id; "id": null is not a valid substitute on the wire.
      refute function_response.key?("id")
    end
  end

  def test_create_preserves_multi_member_any_of_tool_parameter_unions
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tools: [
        {
          type: "function",
          function: {
            name: "lookup",
            description: "Look up a value",
            parameters: {
              type: "object",
              properties: {
                key: {
                  description: "Union-typed key",
                  anyOf: [
                    { type: "string" },
                    { type: "integer" },
                    { type: "null" },
                  ],
                },
              },
              required: ["key"],
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    property = request_body.fetch("tools").fetch(0).fetch("functionDeclarations").fetch(0).fetch("parameters").fetch("properties").fetch("key")

    # Multi-member unions survive: each member converted, the null member
    # only marks the parent nullable, and no single member wins the type.
    assert_equal %w[STRING INTEGER], property.fetch("anyOf").map { |member| member.fetch("type") }
    assert_equal true, property.fetch("nullable")
    assert_equal "Union-typed key", property.fetch("description")
    refute property.key?("type")
  end

  def test_create_does_not_treat_symbol_tool_enums_as_protocol_values
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [
                {
                  content: {
                    parts: [
                      { text: "ok" },
                    ],
                  },
                  finishReason: "STOP",
                },
              ],
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: { type: :function, function: { name: "calculator" } },
      tools: [
        {
          type: :function,
          function: {
            name: "calculator",
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("tools")
    refute request_body.key?("toolConfig")

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      tool_choice: :auto,
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("toolConfig")
  end

  def test_generate_content_maps_thought_input_parts_to_native_thought_parts
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.5-flash",
      input: [
        { role: "user", content: "Question" },
        { role: "assistant", content: [
          { type: "thought", text: "signed reasoning", thoughtSignature: "sig_x" },
          { type: "thought", text: "unsigned reasoning" },
          { type: "thought", text: "" },
          { type: "output_text", text: "answer" },
        ] },
        { role: "user", content: "Follow-up" },
      ]
    )

    parts = JSON.parse(adapter.last_request.fetch(:body)).fetch("contents").flat_map { |content| content.fetch("parts", []) }
    thoughts = parts.select { |part| part["thought"] }
    assert_equal ["signed reasoning", "unsigned reasoning"], thoughts.map { |part| part.fetch("text") }, "empty-text thoughts are dropped"
    assert_equal "sig_x", thoughts.fetch(0).fetch("thoughtSignature")
    refute thoughts.fetch(1).key?("thoughtSignature"), "an unsigned replayed thought omits thoughtSignature"
    assert(parts.any? { |part| part["text"] == "answer" && !part["thought"] }, "the answer text is preserved")
  end

  # Gemini can emit PARALLEL calls to the SAME function in one chunk (no ids).
  # The stream merge's name fallback exists to dedupe cumulative resends across
  # chunks — it must never collapse two distinct same-name calls from one batch.
  def test_stream_keeps_parallel_same_name_tool_calls_distinct
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          raise "stream should use call_stream"
        end

        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate(
            {
              candidates: [{
                content: { parts: [
                  { functionCall: { name: "get_weather", args: { city: "SF" } } },
                  { functionCall: { name: "get_weather", args: { city: "NY" } } },
                ] },
                finishReason: "STOP",
              }],
              usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 3, totalTokenCount: 5 },
            }
          )}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    events = protocol.stream(model: "gemini-3.5-flash", input: "Weather in SF and NY?").to_a

    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    tool_calls = completed.result.tool_calls
    assert_equal 2, tool_calls.length, "one of two parallel same-name calls was dropped by the merge"
    arguments = tool_calls.map { |call| JSON.parse(call.fetch("arguments")).fetch("city") }
    assert_equal %w[SF NY], arguments

    done_events = events.grep(SimpleInference::Responses::Events::ToolCallDone)
    assert_equal 2, done_events.length
  end

  # The name fallback's actual job: an id-less cumulative resend of the same
  # call across chunks still merges to ONE call.
  def test_stream_still_merges_id_less_cumulative_resends_of_the_same_call
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          raise "stream should use call_stream"
        end

        def call_stream(_env)
          chunk = {
            candidates: [{ content: { parts: [{ functionCall: { name: "calculator", args: { expression: "2 + 2" } } }] } }],
          }
          final = {
            candidates: [{
              content: { parts: [{ functionCall: { name: "calculator", args: { expression: "2 + 2" } } }] },
              finishReason: "STOP",
            }],
            usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 },
          }
          yield "data: #{JSON.generate(chunk)}\n\ndata: #{JSON.generate(final)}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    events = protocol.stream(model: "gemini-3.5-flash", input: "2+2?").to_a

    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    assert_equal 1, completed.result.tool_calls.length, "a cumulative resend must still dedupe to one call"
  end

  # --- The declared-vocabulary + extra_body contract (transplant template):
  # request methods accept ONLY their declared symbol options, provider
  # wire fields ride extra_body verbatim, collisions with protocol-built
  # fields raise, and every body exits through finalize_wire_body. ---

  def test_gemini_request_option_keys_are_introspectable
    generate_content_keys = SimpleInference::Protocols::GeminiGenerateContent.request_option_keys

    assert_includes generate_content_keys, :thinking_config
    refute_includes generate_content_keys, :thinkingConfig, "the camelCase spelling is a wire field, not an option"
    assert generate_content_keys.frozen?
  end

  def test_generate_content_unknown_symbol_options_raise_and_point_at_extra_body
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", temperture: 0.2)
      end

    assert_includes error.message, "temperture"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_rejects_the_camel_case_thinking_config_spelling
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", thinkingConfig: { thinkingBudget: 512 })
      end

    assert_includes error.message, "thinkingConfig"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_declared_thinking_config_reaches_the_wire
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", thinking_config: { thinkingBudget: 512, includeThoughts: true })

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      { "thinkingBudget" => 512, "includeThoughts" => true },
      request_body.dig("generationConfig", "thinkingConfig")
    )
  end

  def test_generate_content_extra_body_merges_wire_fields_verbatim
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      max_output_tokens: 64,
      extra_body: {
        "safetySettings" => [{ "category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE" }],
        "cachedContent" => "cachedContents/abc",
      }
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 64, request_body.dig("generationConfig", "maxOutputTokens")
    assert_equal [{ "category" => "HARM_CATEGORY_HARASSMENT", "threshold" => "BLOCK_NONE" }], request_body.fetch("safetySettings")
    assert_equal "cachedContents/abc", request_body.fetch("cachedContent")
  end

  def test_generate_content_extra_body_collisions_with_built_fields_raise
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "gemini-3.5-flash", input: "Hello", max_output_tokens: 64, extra_body: { "generationConfig" => {} })
      end

    assert_includes error.message, "generationConfig"
  end

  def test_generate_content_stream_rejects_unknown_options_before_streaming
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: capturing_gemini_adapter
    )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "gemini-3.5-flash", input: "Hello", tempo: 1)
      end

    assert_includes error.message, "tempo"
    assert_includes error.message, "extra_body"
  end

  def test_generate_content_stream_extra_body_reaches_the_wire
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call_stream(env)
          @last_request = env
          yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }] })}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    protocol.stream(model: "gemini-3.5-flash", input: "Hello", extra_body: { "cachedContent" => "cachedContents/abc" }).to_a

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "cachedContents/abc", request_body.fetch("cachedContent")
  end

  # seed still maps INTO generationConfig (its real wire home); the
  # candidateCount surface no longer exists on this lane.
  def test_create_maps_seed_into_generation_config_without_candidate_count
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", seed: 123)

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("seed"), "seed must not be a top-level wire field"
    assert_equal 123, body.dig("generationConfig", "seed")
    refute body.fetch("generationConfig").key?("candidateCount")
  end

  def test_create_maps_json_object_response_format_to_response_mime_type
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hello", response_format: { type: "json_object" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("response_format"), "response_format must not be a top-level wire field"
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    refute body.fetch("generationConfig").key?("responseJsonSchema")
  end

  def test_create_maps_json_schema_response_format_to_response_json_schema
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    schema = { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }

    protocol.create(
      model: "gemini-3.5-flash",
      input: "Hello",
      response_format: { type: "json_schema", name: "reply", schema: schema, strict: true },
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    assert_equal schema, body.dig("generationConfig", "responseJsonSchema")
  end

  # Load-bearing production mapping (the kernel routes catalog options through
  # this at spec-build time). temperature/top_p/top_k are frozen local
  # rejections for this lane (see the pre-wire rejection tests above), so
  # max_output_tokens is the only surviving sampling-adjacent control.
  def test_create_maps_max_output_tokens_into_generation_config
    adapter = capturing_gemini_adapter
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    protocol.create(model: "gemini-3.5-flash", input: "Hi", max_output_tokens: 64)

    config = JSON.parse(adapter.last_request.fetch(:body)).fetch("generationConfig")
    assert_equal 64, config.fetch("maxOutputTokens")
  end

  def test_generate_content_full_vocabulary_is_pinned
    assert_equal(
      %i[tools tool_choice instructions max_output_tokens temperature top_p top_k reasoning_effort thinking_config seed n response_format],
      SimpleInference::Protocols::GeminiGenerateContent.request_option_keys,
    )
  end

  # --- gemini_generate_content.usage.v1 conformance (deterministic
  # constructions built from the register's wire matrix — NOT wire captures;
  # the 2026-08-09 probe truth they encode lives in the frozen register). ---

  # Per-chunk snapshot progression: usageMetadata rides every chunk and each
  # snapshot REPLACES the previous one; the final chunk is authoritative.
  def test_stream_usage_snapshots_replace_per_chunk_and_final_chunk_wins
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hel" }] } }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 2, totalTokenCount: 9 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "lo" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 110, totalTokenCount: 117 } })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 110, result.usage.fetch("output_tokens")
    assert_equal 117, result.usage.fetch("total_tokens")
  end

  # No usage destruction: a terminal chunk WITHOUT usageMetadata must not wipe
  # the last snapshot an earlier chunk carried (deterministic construction).
  def test_stream_retains_last_usage_snapshot_when_terminal_chunk_lacks_usage_metadata
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hello" }] } }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 5, totalTokenCount: 12 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "!" }] }, finishReason: "STOP" }] })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    refute_nil result.usage, "the last usageMetadata snapshot must survive a bare terminal chunk"
    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 12, result.usage.fetch("total_tokens")
  end

  # Modality-detail rows and serviceTier are bounded evidence: IMAGE/AUDIO
  # rows promote to canonical subcounts, every row plus serviceTier and
  # toolUsePromptTokenCount is retained verbatim, and nothing is fabricated.
  def test_usage_retains_modality_detail_rows_and_service_tier_as_bounded_evidence
    prompt_tokens_details = [
      { "modality" => "TEXT", "tokenCount" => 4 },
      { "modality" => "IMAGE", "tokenCount" => 258 },
      { "modality" => "AUDIO", "tokenCount" => 32 },
      { "modality" => "VIDEO", "tokenCount" => 99 },
    ]
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: {
                promptTokenCount: 393,
                candidatesTokenCount: 3,
                totalTokenCount: 396,
                promptTokensDetails: prompt_tokens_details,
                toolUsePromptTokenCount: 11,
                serviceTier: "standard",
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal 258, result.usage.fetch("image_input_tokens")
    assert_equal 32, result.usage.fetch("audio_input_tokens")
    assert_equal prompt_tokens_details, result.usage.fetch("promptTokensDetails")
    assert_equal "standard", result.usage.fetch("serviceTier")
    assert_equal 11, result.usage.fetch("toolUsePromptTokenCount")
    refute result.usage.key?("video_input_tokens"), "VIDEO has no canonical subcount — bounded evidence only"
  end

  # Presence-vs-zero: a field absent on the wire stays absent — the parser
  # never fabricates a 0 (deterministic construction).
  def test_usage_preserves_presence_versus_zero
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: { promptTokenCount: 5, totalTokenCount: 5 },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal 5, result.usage.fetch("input_tokens")
    refute result.usage.key?("output_tokens"), "absent candidatesTokenCount must not become 0"
    refute result.usage.key?("reasoning_tokens")
    refute result.usage.key?("cache_read_input_tokens")
    refute result.usage.key?("serviceTier")
  end

  # --- Terminal recognition: the frozen 18-value released-SDK FinishReason
  # enum, and interruption on streams that never carry one. ---

  FULL_FINISH_REASON_ENUM = %w[
    FINISH_REASON_UNSPECIFIED STOP MAX_TOKENS SAFETY RECITATION LANGUAGE OTHER
    BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY
    UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS IMAGE_PROHIBITED_CONTENT NO_IMAGE
    IMAGE_RECITATION IMAGE_OTHER
  ].freeze

  def test_create_recognizes_the_full_18_value_finish_reason_enum
    assert_equal 18, FULL_FINISH_REASON_ENUM.length

    FULL_FINISH_REASON_ENUM.each do |reason|
      adapter = Class.new(SimpleInference::HTTPAdapter) do
        define_method(:call) do |_env|
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: reason }] }),
          }
        end
      end.new

      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )
      result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

      assert_equal reason, result.finish_reason
    end
  end

  def test_stream_accepts_extended_enum_terminals
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "TOO_MANY_TOOL_CALLS" }] })}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "TOO_MANY_TOOL_CALLS", result.finish_reason
  end

  # A finishReason outside the frozen enum cannot be silently classified as a
  # clean terminal — fail closed (deterministic malformed construction).
  def test_unknown_finish_reason_fails_closed
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "BANANA" }] }),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
        protocol.create(model: "gemini-3.7-flash", input: "Hello")
      end

    assert_includes error.message, "BANANA"
  end

  # The JSON fallback (a gateway ignored Accept and returned one plain body;
  # no SSE events fired) still recognizes its terminal and usage snapshot
  # (deterministic construction).
  def test_stream_json_fallback_recognizes_terminal_and_usage
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                candidates: [{ content: { parts: [{ text: "Hello" }] }, finishReason: "STOP" }],
                usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 3, totalTokenCount: 5 },
              }
            ),
          }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "Hello", result.output_text
    assert_equal "STOP", result.finish_reason
    assert_equal 5, result.usage.fetch("total_tokens")
  end

  # A PROMPT BLOCK IS A FINISH, NOT A TRANSPORT FAILURE: Google answers no
  # candidate by design, so the Result has no items; its typed detail says
  # the PROMPT was declined (distinct from a candidate's word of the same
  # name), the block reason rides Result#refusal verbatim as the category,
  # and the billed prompt work stays on the usage.
  def test_create_prompt_block_is_a_typed_refusal_with_usage
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({
            promptFeedback: { blockReason: "SAFETY" },
            usageMetadata: { promptTokenCount: 7, totalTokenCount: 7 },
          }),
        }
      end
    end.new
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "PROMPT_SAFETY", result.finish_detail
    assert_equal SimpleInference::Responses::Refusal.new(category: "SAFETY", explanation: nil), result.refusal
    assert_equal "", result.output_text
    assert_empty result.output_items
    assert_empty result.tool_calls
    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 7, result.usage.fetch("total_tokens")
    assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
  end

  def test_stream_prompt_block_is_a_typed_block_not_an_interruption
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield "data: #{JSON.generate({
          promptFeedback: { blockReason: "PROHIBITED_CONTENT" },
          usageMetadata: { promptTokenCount: 9, totalTokenCount: 9 },
        })}\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "PROMPT_PROHIBITED_CONTENT", result.finish_detail
    assert_equal "PROHIBITED_CONTENT", result.refusal.category
    assert_equal 9, result.usage.fetch("input_tokens")
    assert_equal "blocked", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
  end

  def test_the_prompt_blocked_error_is_retired
    refute SimpleInference::Protocols::GeminiGenerateContent.const_defined?(:PromptBlockedError, false),
      "a prompt block is a Result now; nothing raises it"
  end

  # Fail closed on a block reason outside the released SDK's frozen
  # BlockedReason enum, exactly as on an unknown finishReason: an
  # unclassified block must never read as a clean, empty finish.
  def test_an_unknown_prompt_block_reason_is_refused_loudly
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ promptFeedback: { blockReason: "SOMETHING_NEW" } }),
        }
      end
    end.new

    assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
      gemini_protocol(adapter: adapter).create(model: "gemini-3.7-flash", input: "Hello")
    end
  end

  # A SAFETY-class candidate stop is a typed refusal whose category IS
  # Google's word; a content-protection stop carries its word the same way
  # and types as blocked.
  def test_a_safety_finish_is_a_typed_refusal_with_its_category
    result = gemini_protocol(adapter: finish_adapter("SAFETY")).create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "SAFETY", result.finish_detail
    assert_equal SimpleInference::Responses::Refusal.new(category: "SAFETY", explanation: nil), result.refusal
  end

  def test_an_spii_finish_is_a_typed_block
    result = gemini_protocol(adapter: finish_adapter("SPII")).create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "SPII", result.finish_detail
    assert_equal "SPII", result.refusal.category
    assert_equal "blocked", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: "SPII")
  end

  def test_a_streamed_safety_finish_carries_the_refusal
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "par" }] } }] })}\n\n"
        yield "data: #{JSON.generate({ candidates: [{ content: { parts: [] }, finishReason: "SAFETY" }],
                                       usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 1, totalTokenCount: 3 } })}\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new

    result = gemini_protocol(adapter: adapter).stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "SAFETY", result.finish_detail
    assert_equal "SAFETY", result.refusal.category
  end

  def test_unclassified_finishes_carry_no_refusal
    %w[STOP MAX_TOKENS OTHER].each do |reason|
      result = gemini_protocol(adapter: finish_adapter(reason)).create(model: "gemini-3.7-flash", input: "Hello")

      assert_nil result.refusal, reason
    end
  end

  # A stream that runs to HTTP completion without ANY candidate carrying a
  # finishReason is an INTERRUPTION — an explicit typed marker, never a silent
  # normal Result (deterministic interruption construction, not a capture).
  def test_stream_without_a_terminal_chunk_is_an_explicit_interruption
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hel" }] } }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 1, totalTokenCount: 3 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "lo" }] } }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 2, totalTokenCount: 4 } })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    stream = protocol.stream(model: "gemini-3.7-flash", input: "Hello")

    error =
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::InterruptedStreamError) do
        stream.to_a
      end

    assert_includes error.message, "finishReason"
    assert_kind_of SimpleInference::StreamError, error
  end


  private


  def finish_adapter(reason)
    Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: reason }] }),
        }
      end
    end.new
  end

  def gemini_protocol(adapter:)
    SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
  end

  # Terminal body whose usageMetadata is exactly the given fields — used to
  # pin presence-vs-zero and non-coercion at the parse seam.
  def usage_metadata_adapter(**usage_metadata)
    Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: usage_metadata,
            }
          ),
        }
      end
    end.new
  end

  def exploding_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "a rejected request must never touch the adapter"
      end

      def call_stream(_env)
        raise "a rejected request must never touch the adapter"
      end
    end.new
  end

  def capturing_gemini_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: { promptTokenCount: 1, candidatesTokenCount: 1, totalTokenCount: 2 },
            }
          ),
        }
      end
    end.new
  end
end
