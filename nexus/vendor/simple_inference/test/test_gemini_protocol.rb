require "json"
require "test_helper"

class TestGeminiProtocol < Minitest::Test
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
end
