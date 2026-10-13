require "json"
require "test_helper"

class TestOpenAIResponsesProtocol < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  def test_responses_create_posts_to_configured_path
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
                "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com/v1",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello")

    assert_equal :post, adapter.last_request[:method]
    assert_equal "http://example.com/v1/responses", adapter.last_request[:url]
    body = JSON.parse(adapter.last_request[:body])
    assert_equal "m", body.fetch("model")
    assert_equal "Hello", body.fetch("input")
  end

  def test_responses_create_keeps_api_prefix_when_base_url_includes_it_and_path_is_short
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com/v1",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello")

    assert_equal "http://example.com/v1/responses", adapter.last_request[:url]
  end

  def test_responses_create_preserves_short_paths_when_base_url_has_no_api_prefix
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello")

    assert_equal "http://example.com/responses", adapter.last_request[:url]
  end

  def test_responses_create_maps_reasoning_effort_to_nested_reasoning_with_summary
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "xhigh")

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "reasoning_effort"
    assert_equal({ "effort" => "xhigh", "summary" => "auto" }, body.fetch("reasoning"))
  end

  # Frozen reasoning contract row (conformance register): the wire effort
  # vocabulary is the closed set none|minimal|low|medium|high|xhigh|max.
  # Every in-set value must lower to the wire verbatim (per-model subsets are
  # a resource/catalog gate, not a wire gate).
  def test_reasoning_effort_frozen_vocabulary_lowers_verbatim
    %w[none minimal low medium high xhigh max].each do |effort|
      adapter = capturing_responses_adapter
      protocol =
        SimpleInference::Protocols::OpenAIResponses.new(
          base_url: "http://example.com", responses_path: "/responses", adapter: adapter
        )

      protocol.responses_create(model: "m", input: "Hello", reasoning_effort: effort)

      body = JSON.parse(adapter.last_request.fetch(:body))
      assert_equal effort, body.fetch("reasoning").fetch("effort")
    end
  end

  def test_out_of_set_reasoning_effort_is_rejected_locally
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "ultra")
      end

    assert_includes error.message, "ultra"
    assert_includes error.message, "none, minimal, low, medium, high, xhigh, max"
  end

  def test_out_of_set_effort_in_nested_reasoning_hash_is_rejected_locally
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", reasoning: { effort: "turbo" })
      end

    assert_includes error.message, "turbo"
  end

  # Frozen reasoning contract row: reasoning.summary ∈ auto|concise|detailed
  # (the flat reasoning_summary: "none" spelling is a LOCAL omit sentinel and
  # never reaches the wire — covered above).
  def test_out_of_set_reasoning_summary_is_rejected_locally
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "medium", reasoning_summary: "verbose")
      end

    assert_includes error.message, "verbose"
    assert_includes error.message, "auto, concise, detailed"
  end

  # Frozen reasoning contract row: reasoning.context ∈ auto|current_turn|all_turns.
  def test_out_of_set_reasoning_context_is_rejected_locally
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", reasoning: { effort: "medium", context: "every_turn" })
      end

    assert_includes error.message, "every_turn"
    assert_includes error.message, "auto, current_turn, all_turns"
  end

  def test_an_in_vocabulary_reasoning_context_rides_the_wire
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m", input: "Hello", reasoning: { effort: "medium", context: "all_turns" }, reasoning_summary: "none"
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "effort" => "medium", "context" => "all_turns" }, body.fetch("reasoning"))
  end

  def test_responses_create_allows_reasoning_summary_override
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "medium", reasoning_summary: "detailed")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "effort" => "medium", "summary" => "detailed" }, body.fetch("reasoning"))
  end

  def test_responses_create_allows_reasoning_summary_to_be_disabled
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "medium", reasoning_summary: "none")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "effort" => "medium" }, body.fetch("reasoning"))
  end

  def test_responses_create_with_reasoning_captures_encrypted_content_statelessly
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(model: "m", input: "Hello", reasoning_effort: "medium")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal false, body.fetch("store"), "reasoning capture forces stateless store:false"
    assert_includes body.fetch("include"), "reasoning.encrypted_content"
  end

  def test_responses_create_respects_caller_supplied_store_and_include
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m", input: "Hello", reasoning_effort: "medium",
      store: true, include: ["file_search_call.results"]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("store"), "a caller-set store is not overwritten"
    assert_includes body.fetch("include"), "file_search_call.results"
    assert_includes body.fetch("include"), "reasoning.encrypted_content"
  end

  def test_responses_coerces_assistant_input_text_to_output_text_and_passes_others_through
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false,
      input: [
        { "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "prior answer" }] },
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "question" }] },
        { "type" => "reasoning", "encrypted_content" => "blob" },
      ]
    )

    input = JSON.parse(adapter.last_request.fetch(:body)).fetch("input")
    assert_equal "output_text", input[0].fetch("content").first.fetch("type"), "assistant input_text becomes output_text"
    assert_equal "input_text", input[1].fetch("content").first.fetch("type"), "user parts are untouched"
    assert_equal "reasoning", input[2].fetch("type"), "role-less items pass through unchanged"
  end

  # The kernel advertises tools in the chat-completions nested shape (its
  # canonical form). The Responses API requires the flat function shape and
  # 400s on the envelope ("Missing required parameter: 'tools[0].name'").
  def test_responses_flattens_chat_shaped_function_tools_for_the_wire
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false, input: "hi",
      tools: [
        {
          "type" => "function",
          "function" => {
            "name" => "bash", "description" => "run a command",
            "parameters" => { "type" => "object" }, "strict" => true,
          },
        },
        { "type" => "function", "name" => "already_flat", "parameters" => { "type" => "object" } },
        { "type" => "web_search" },
      ]
    )

    tools = JSON.parse(adapter.last_request.fetch(:body)).fetch("tools")
    nested = tools.fetch(0)
    assert_equal "function", nested.fetch("type")
    assert_equal "bash", nested.fetch("name")
    assert_equal "run a command", nested.fetch("description")
    assert_equal({ "type" => "object" }, nested.fetch("parameters"))
    assert_equal true, nested.fetch("strict")
    refute nested.key?("function"), "the chat envelope must not reach the Responses wire"
    assert_equal "already_flat", tools.fetch(1).fetch("name"), "flat tools pass through"
    assert_equal({ "type" => "web_search" }, tools.fetch(2), "built-in tools pass through verbatim")
  end

  # The kernel splices prior-round tool calls as chat-style messages (an
  # assistant message with canonical flat tool_calls plus role:"tool"
  # results). The Responses wire has no tool_calls/tool-role vocabulary —
  # they must become function_call / function_call_output items.
  def test_responses_converts_chat_tool_splice_to_function_call_items
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false,
      input: [
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "go" }] },
        {
          "role" => "assistant",
          "content" => [{ "type" => "input_text", "text" => "running it" }],
          "tool_calls" => [{ "id" => "call_1", "name" => "bash", "arguments" => "{\"command\":\"ls\"}" }],
        },
        { "role" => "tool", "tool_call_id" => "call_1", "name" => "bash", "content" => "README.md" },
      ]
    )

    input = JSON.parse(adapter.last_request.fetch(:body)).fetch("input")
    assert_equal "user", input.fetch(0).fetch("role")

    assistant = input.fetch(1)
    assert_equal "assistant", assistant.fetch("role")
    assert_equal "output_text", assistant.fetch("content").first.fetch("type")
    refute assistant.key?("tool_calls"), "chat vocabulary must not reach the Responses wire"

    call = input.fetch(2)
    assert_equal(
      { "type" => "function_call", "call_id" => "call_1", "name" => "bash", "arguments" => "{\"command\":\"ls\"}" },
      call
    )

    output = input.fetch(3)
    assert_equal(
      { "type" => "function_call_output", "call_id" => "call_1", "output" => "README.md" },
      output
    )
  end

  # A tool result's `is_error` is the kernel's neutral flag (Anthropic's
  # tool_result field). The Responses wire has no such parameter: OpenAI
  # answers 400 "Unknown parameter: 'input[n].is_error'" (gpt-6-luna, the
  # first errored tool of a loop). The flag stays off the wire; the output
  # text, which carries the kernel's error marker, and the pairing `name`
  # the wire tolerates ride as handed.
  def test_responses_keeps_a_tool_results_error_flag_off_the_wire
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false,
      input: [
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "go" }] },
        { "type" => "function_call", "call_id" => "call_1", "name" => "bash", "arguments" => "{}" },
        { "type" => "function_call_output", "call_id" => "call_1", "name" => "bash",
          "output" => "<tool_use_error>boom</tool_use_error>", "is_error" => true },
      ]
    )

    output = JSON.parse(adapter.last_request.fetch(:body)).fetch("input").last
    assert_equal(
      { "type" => "function_call_output", "call_id" => "call_1", "name" => "bash",
        "output" => "<tool_use_error>boom</tool_use_error>" },
      output
    )
  end

  # The assistant's `phase` (commentary | final_answer) is the wire's own
  # label on a message it produced, and the vendor asks for it back on
  # every follow-up: a preamble resent without it reads as a final answer.
  # The coercion rebuilds only the content parts and the call splice, so
  # the key rides as handed — on a plain message and on the message item a
  # tool_calls splice keeps.
  def test_responses_resends_the_assistant_phase_it_was_handed
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false,
      input: [
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "go" }] },
        { "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "Reading it." }],
          "phase" => "commentary" },
        { "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "Running it." }],
          "phase" => "commentary",
          "tool_calls" => [{ "id" => "call_1", "name" => "bash", "arguments" => "{}" }] },
      ]
    )

    input = JSON.parse(adapter.last_request.fetch(:body)).fetch("input")
    assert_equal(
      { "role" => "assistant", "content" => [{ "type" => "output_text", "text" => "Reading it." }],
        "phase" => "commentary" },
      input.fetch(1)
    )
    assert_equal(
      { "role" => "assistant", "content" => [{ "type" => "output_text", "text" => "Running it." }],
        "phase" => "commentary" },
      input.fetch(2), "the splice's message item keeps the phase; the call becomes its own item"
    )
    assert_equal "function_call", input.fetch(3).fetch("type")
  end

  def test_responses_drops_the_assistant_message_when_a_tool_call_splice_has_no_text
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses(
      model: "m", stream: false,
      input: [
        { "role" => "user", "content" => "go" },
        {
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [{ "id" => "call_9", "name" => "zap", "arguments" => "{}" }],
        },
        { "role" => "tool", "tool_call_id" => "call_9", "content" => "ok" },
      ]
    )

    input = JSON.parse(adapter.last_request.fetch(:body)).fetch("input")
    types_and_roles = input.map { |item| item["type"] || item["role"] }
    assert_equal ["user", "function_call", "function_call_output"], types_and_roles,
                 "an empty assistant shell must not become an empty message item"
  end

  def test_responses_create_maps_response_format_to_text_format
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] },
                ],
              }
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_create(
      model: "m",
      input: "Hello",
      response_format: { type: "json_object" },
      text: { verbosity: "low" },
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "response_format"
    assert_equal(
      {
        "verbosity" => "low",
        "format" => { "type" => "json_object" },
      },
      body.fetch("text")
    )
  end

  def test_responses_stream_maps_reasoning_effort_to_nested_reasoning
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call_stream(env)
          @last_request = env
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: "data: [DONE]\n\n" }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: adapter,
      )

    protocol.responses_stream(model: "m", input: "Hello", reasoning_effort: "xhigh").to_a

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("stream")
    refute_includes body, "reasoning_effort"
    assert_equal({ "effort" => "xhigh", "summary" => "auto" }, body.fetch("reasoning"))
  end

  def test_responses_raises_validation_error_when_model_missing
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "adapter should not be reached"
      end
    end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com/v1",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses(model: nil, input: "Hello")
      end

    assert_includes error.message, "model is required"
  end

  def test_responses_stream_yields_parsed_sse_events
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"Hel"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"lo"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          # Chunked to exercise buffering.
          [sse[0, 11], sse[11, 13], sse[24..]].compact.each { |chunk| yield chunk }

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.responses_stream(model: "m", input: "Hello").to_a

    assert_equal(
      [
        { "type" => "response.output_text.delta", "delta" => "Hel" },
        { "type" => "response.output_text.delta", "delta" => "lo" },
        { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
      ],
      events
    )
  end

  def test_responses_stream_parses_sse_body_when_content_type_is_missing
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: response.created\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"Hel"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"lo"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          { status: 200, headers: {}, body: sse }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.responses_stream(model: "m", input: "Hello").to_a

    assert_equal(
      [
        { "type" => "response.output_text.delta", "delta" => "Hel" },
        { "type" => "response.output_text.delta", "delta" => "lo" },
        { "type" => "response.completed", "response" => { "usage" => { "input_tokens" => 1, "output_tokens" => 2 } } },
      ],
      events,
    )
  end

  def test_responses_high_level_accumulates_text_and_extracts_usage
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"a"}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"b"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":4,"input_tokens_details":{"cached_tokens":2}}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal ["a", "b"], deltas
    assert_equal "ab", result.output_text
    assert_equal(
      {
        "input_tokens" => 3,
        "output_tokens" => 4,
        "input_tokens_details" => {
          "cached_tokens" => 2,
        },
      },
      result.usage
    )
  end

  def test_stream_yields_reasoning_text_and_summary_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"Need "}\n\n)
          sse << %(data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"tool."}\n\n)
          sse << %(data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"Used a tool."}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"Done"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"output":[{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Used a tool."}],"content":[{"type":"reasoning_text","text":"Need tool."}]}],"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.stream(model: "m", input: "Hello").to_a
    reasoning_events = events.grep(SimpleInference::Responses::Events::ReasoningDelta)
    result = events.last.result

    assert_equal ["Need ", "tool.", "Used a tool."], reasoning_events.map(&:delta)
    assert_equal ["reasoning_text", "reasoning_text", "reasoning_summary"], reasoning_events.map(&:kind)
    assert_equal "Done", result.output_text
    assert_equal "reasoning", result.output_items.fetch(0).fetch("type")
  end

  def test_stream_yields_reasoning_summary_delta_spelling
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.reasoning_summary.delta","item_id":"rs_1","summary_index":0,"delta":"Plan "}\n\n)
          sse << %(data: {"type":"response.reasoning_summary.delta","item_id":"rs_1","summary_index":0,"delta":"made."}\n\n)
          sse << %(data: {"type":"response.reasoning_summary.done","item_id":"rs_1","summary_index":0,"text":"Plan made."}\n\n)
          sse << %(data: {"type":"response.output_text.delta","delta":"Done"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.stream(model: "m", input: "Hello").to_a
    reasoning_events = events.grep(SimpleInference::Responses::Events::ReasoningDelta)

    assert_equal ["Plan ", "made."], reasoning_events.map(&:delta)
    assert_equal ["reasoning_summary", "reasoning_summary"], reasoning_events.map(&:kind)
    assert_equal ["rs_1", "rs_1"], reasoning_events.map(&:item_id)
  end

  def test_responses_high_level_streaming_raises_error_payload_on_response_failed
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: failed_terminal_adapter,
      )

    error =
      assert_raises(SimpleInference::Error) do
        protocol.responses(model: "m", input: "Hello", stream: true)
      end

    assert_includes error.message, "server_error"
    assert_includes error.message, "provider exploded"
  end

  # Matrix: the `failed`-terminal usage guarantee is unprobed, but WHEN the
  # wire carries usage on response.failed it is billing evidence and must ride
  # the failure surface instead of being discarded. Deterministic construction
  # (not a wire capture).
  def test_response_failed_raises_typed_error_retaining_wire_usage_evidence
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: failed_terminal_adapter,
      )

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.responses(model: "m", input: "Hello", stream: true)
      end

    assert_equal "server_error", error.code
    assert_equal "provider exploded", error.error_message
    assert_equal(
      { "input_tokens" => 7, "output_tokens" => 0 },
      error.usage,
      "wire usage on the failed terminal is evidence — presence (including an explicit zero) preserved"
    )
    assert_equal "failed", error.response_body.fetch("status")
  end

  # THE SERVED TIER rides a failed terminal's usage exactly as it rides a
  # completed one's: settlement prices a billed failure by the tier the
  # response names (a flex-served failure bills at half, fast at double),
  # so the failure surface must never drop the word.
  def test_response_failed_usage_carries_the_served_tier
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.failed","response":{"status":"failed","service_tier":"flex","error":{"code":"server_error","message":"boom"},"usage":{"input_tokens":7,"output_tokens":0}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.responses(model: "m", input: "Hello", stream: true)
      end

    assert_equal({ "input_tokens" => 7, "output_tokens" => 0, "service_tier" => "flex" }, error.usage)
  end

  # Deterministic construction: a failed terminal WITHOUT usage keeps usage
  # absent on the failure surface — presence-vs-zero, never fabricate 0.
  def test_response_failed_without_wire_usage_keeps_usage_absent
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.responses(model: "m", input: "Hello", stream: true)
      end

    assert_nil error.usage, "absent wire usage stays absent on the failure surface"
  end

  # Deterministic construction: a bare {"type":"error"} SSE event (documented
  # alongside the three response.* terminals) gets typed recognition carrying
  # the payload instead of falling through unrecognized.
  def test_bare_error_event_type_raises_typed_error_carrying_payload
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"error","code":"ERR_RATE","message":"slow down","sequence_number":3}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::StreamErrorEventError) do
        protocol.responses_stream(model: "m", input: "Hello").to_a
      end

    assert_includes error.message, "ERR_RATE"
    assert_includes error.message, "slow down"
    assert_equal "error", error.payload.fetch("type")
    assert_equal 3, error.payload.fetch("sequence_number")
  end

  # Deterministic construction: the `event: error` SSE NAME spelling (payload
  # without a "type" field) is recognized too.
  def test_bare_error_event_name_raises_typed_error_carrying_payload
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: error\n)
          sse << %(data: {"error":{"code":"overloaded","message":"try later"}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::StreamErrorEventError) do
        protocol.responses_stream(model: "m", input: "Hello").to_a
      end

    assert_includes error.message, "overloaded"
    assert_includes error.message, "try later"
    assert_equal({ "error" => { "code" => "overloaded", "message" => "try later" } }, error.payload)
  end

  def test_high_level_stream_raises_typed_error_on_bare_error_event
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"par"}\n\n)
          sse << %(data: {"type":"error","code":"ERR_RATE","message":"slow down"}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::Protocols::OpenAIResponses::StreamErrorEventError) do
      protocol.stream(model: "m", input: "Hello").each { |_event| nil }
    end
  end

  def test_stream_raises_error_payload_on_response_failed
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: failed_terminal_adapter,
      )

    error =
      assert_raises(SimpleInference::Error) do
        protocol.stream(model: "m", input: "Hello").each { |_event| nil }
      end

    assert_includes error.message, "server_error"
    assert_includes error.message, "provider exploded"
  end

  # Terminal discipline: response.incomplete keeps the wire status ENUM
  # ("incomplete") and carries incomplete_details.reason as a DISTINCT field —
  # the reason never overwrites the status. Usage on the incomplete terminal
  # is probe-verified (2026-08-09) and must be preserved.
  def test_stream_returns_result_from_response_incomplete_terminal_event
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: incomplete_terminal_adapter,
      )

    events = protocol.stream(model: "m", input: "Hello").to_a
    result = events.last.result

    assert_equal "incomplete", result.finish_reason, "the status enum is not overwritten with the cutoff reason"
    assert_equal "incomplete", result.provider_response.body.fetch("status")
    assert_equal "max_output_tokens", result.provider_response.body.dig("incomplete_details", "reason"),
                 "the cutoff cause stays a distinct field"
    assert_equal "par", result.output_text
    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, result.usage)
  end

  def test_responses_high_level_streaming_returns_usage_from_response_incomplete
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: incomplete_terminal_adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal ["par"], deltas
    assert_equal "par", result.output_text
    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, result.usage)
    assert_equal "max_output_tokens", result.incomplete_reason,
                 "the reason rides the result surface as its own field"
  end

  def test_responses_high_level_streaming_leaves_incomplete_reason_absent_on_completed
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"ok"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_nil result.incomplete_reason
  end

  # Deterministic construction of a NON-streaming incomplete body (not a wire
  # capture): same discipline — status enum kept, reason distinct.
  def test_non_streaming_incomplete_body_keeps_status_and_surfaces_reason
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          body = {
            "status" => "incomplete",
            "incomplete_details" => { "reason" => "max_output_tokens" },
            "output" => [
              { "type" => "message", "content" => [{ "type" => "output_text", "text" => "par" }] },
            ],
            "usage" => { "input_tokens" => 7, "output_tokens" => 8 },
          }

          { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    responses_result = protocol.responses(model: "m", input: "Hello", stream: false)
    assert_equal "max_output_tokens", responses_result.incomplete_reason
    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, responses_result.usage)

    result = protocol.create(model: "m", input: "Hello")
    assert_equal "incomplete", result.finish_reason
    assert_equal "max_output_tokens", result.provider_response.body.dig("incomplete_details", "reason")
  end

  # A REFUSAL PART is the model declining, not its answer: the finish is
  # typed "refusal" (the status says only "completed"), the part's sentence
  # rides Result#refusal as the explanation, and no category is invented —
  # this wire sends none.
  def test_a_refusal_part_is_a_typed_refusal_and_never_the_answer
    protocol = responses_protocol_answering(
      "status" => "completed",
      "output" => [
        { "type" => "message", "role" => "assistant",
          "content" => [{ "type" => "refusal", "refusal" => "I can't help with that." }] },
      ],
      "usage" => { "input_tokens" => 4, "output_tokens" => 6 }
    )

    result = protocol.create(model: "m", input: "Hello")

    assert_equal "refusal", result.finish_detail
    assert_equal "completed", result.finish_reason
    assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: "I can't help with that."),
      result.refusal
    assert_equal "", result.output_text
    assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "openai_responses", detail: result.finish_detail)
  end

  def test_a_content_filter_cut_is_a_typed_refusal_with_no_invented_details
    protocol = responses_protocol_answering(
      "status" => "incomplete",
      "incomplete_details" => { "reason" => "content_filter" },
      "output" => [],
      "usage" => { "input_tokens" => 4, "output_tokens" => 0 }
    )

    result = protocol.create(model: "m", input: "Hello")

    assert_equal "content_filter", result.finish_detail
    assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: nil), result.refusal
    assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "openai_responses", detail: result.finish_detail)
  end

  def test_a_streamed_refusal_part_never_reaches_the_text_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          message = { "id" => "msg_1", "type" => "message", "role" => "assistant",
                      "content" => [{ "type" => "refusal", "refusal" => "No." }] }
          sse = +""
          sse << %(data: #{JSON.generate("type" => "response.output_item.added", "output_index" => 0, "item" => message.merge("content" => []))}\n\n)
          sse << %(data: {"type":"response.refusal.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"No."}\n\n)
          sse << %(data: {"type":"response.refusal.done","item_id":"msg_1","output_index":0,"content_index":0,"refusal":"No."}\n\n)
          sse << %(data: #{JSON.generate("type" => "response.output_item.done", "output_index" => 0, "item" => message)}\n\n)
          sse << %(data: #{JSON.generate("type" => "response.completed", "response" => { "status" => "completed", "output" => [message], "usage" => { "input_tokens" => 1, "output_tokens" => 2 } })}\n\n)
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol = SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", adapter: adapter)

    stream = protocol.stream(model: "m", input: "Hello")
    events = stream.to_a

    assert_empty events.grep(SimpleInference::Responses::Events::TextDelta)
    assert_equal "refusal", stream.final_result.finish_detail
    assert_equal "No.", stream.final_result.refusal.explanation
    assert_equal "", stream.final_result.output_text
  end

  def test_a_clean_responses_answer_carries_no_refusal
    protocol = responses_protocol_answering(
      "status" => "completed",
      "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] }],
      "usage" => { "input_tokens" => 1, "output_tokens" => 1 }
    )

    result = protocol.create(model: "m", input: "Hello")

    assert_nil result.refusal
    assert_nil result.finish_detail
  end

  # Presence-vs-zero: a completed terminal whose body carries NO usage yields
  # an ABSENT usage (nil) — never a fabricated zero hash.
  def test_completed_terminal_without_usage_keeps_usage_absent
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"ok"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"status":"completed"}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal "ok", result.output_text
    assert_nil result.usage, "absent wire usage stays absent — never fabricated as 0"
  end

  # Matrix: usage rides the terminal event; response.incomplete carries it
  # too (probe-verified). The per-event usage extractor must recognize the
  # incomplete terminal, not only response.completed.
  def test_streaming_state_captures_usage_from_the_incomplete_terminal_event
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: incomplete_terminal_adapter,
      )

    usages = []
    protocol.send(:streamed_responses_result, { model: "m", input: "Hello" }) do |_event, fold|
      usages << fold.usage
    end

    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, usages.last)
  end

  # A stream ending WITHOUT any terminal event (no response.completed /
  # response.incomplete / response.failed) is an INTERRUPTION — a typed
  # StreamError, never a silent partial result. Deterministic construction.
  def test_responses_high_level_streaming_requires_completed_terminal_event
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"partial"}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    error =
      assert_raises(SimpleInference::StreamError) do
        protocol.responses(model: "m", input: "Hello", stream: true)
      end

    assert_includes error.message, "response.completed"
    assert_match(/interrupted/, error.message)
  end

  def test_stream_ending_without_terminal_event_is_an_interruption
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"partial"}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::StreamError) do
      protocol.stream(model: "m", input: "Hello").each { |_event| nil }
    end
  end

  def test_responses_high_level_streaming_falls_back_to_non_sse_json_success_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "fallback ok" }] },
                ],
                "usage" => { "input_tokens" => 5, "output_tokens" => 6 },
              },
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal [], deltas
    assert_equal "fallback ok", result.output_text
    assert_equal({ "input_tokens" => 5, "output_tokens" => 6 }, result.usage)
  end

  def test_responses_high_level_streaming_falls_back_to_headerless_json_success_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: {},
            body: JSON.generate(
              {
                "output" => [
                  { "type" => "message", "content" => [{ "type" => "output_text", "text" => "headerless ok" }] },
                ],
                "usage" => { "input_tokens" => 7, "output_tokens" => 8 },
              },
            ),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    deltas = []
    result =
      protocol.responses(model: "m", input: "Hello", stream: true) do |delta|
        deltas << delta
      end

    assert_equal [], deltas
    assert_equal "headerless ok", result.output_text
    assert_equal({ "input_tokens" => 7, "output_tokens" => 8 }, result.usage)
  end

  def test_responses_high_level_extracts_function_calls_from_body
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_req)
          body = {
            "output" => [
              {
                "type" => "function_call",
                "id" => "item_1",
                "call_id" => "call_1",
                "name" => "echo",
                "arguments" => "{\"text\":\"hello\"}",
              },
              {
                "type" => "message",
                "role" => "assistant",
                "content" => [{ "type" => "output_text", "text" => "ok" }],
              },
            ],
            "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
          }

          { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: false)

    items = result.output_items
    assert items.is_a?(Array)
    fc = items.find { |i| i.is_a?(Hash) && i["type"] == "function_call" }
    refute_nil fc
    assert_equal "call_1", fc["call_id"]
    assert_equal "echo", fc["name"]
    assert_equal "{\"text\":\"hello\"}", fc["arguments"]
  end

  def test_responses_high_level_streaming_reconstructs_function_call_output_items
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":""}}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"{\\"text\\":\\"he"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"llo\\"}"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"item_1","output_index":0,"name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal({ "input_tokens" => 1, "output_tokens" => 2 }, result.usage)
    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
    assert_equal "{\"text\":\"hello\"}", function_call["arguments"]
  end

  def test_responses_high_level_streaming_enriches_function_call_items_from_output_item_done
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"item_1","output_index":0,"name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}\n\n)
          sse << %(data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
  end

  def test_responses_high_level_streaming_preserves_arguments_when_output_item_done_is_sparse
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"{\\"text\\":\\"he"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"llo\\"}"}\n\n)
          sse << %(data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":""}}\n\n)
          sse << %(data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "Hello", stream: true)

    assert_equal 1, result.output_items.length
    function_call = result.output_items.first
    assert_equal "function_call", function_call["type"]
    assert_equal "call_1", function_call["call_id"]
    assert_equal "echo", function_call["name"]
    assert_equal "{\"text\":\"hello\"}", function_call["arguments"]
  end

  def test_responses_stream_raises_decode_error_for_malformed_sse_json
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          yield %(data: {"type":"response.output_text.delta","delta":"oops"\n\n)
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::DecodeError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_wraps_timeout_as_timeout_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          raise Timeout::Error, "timed out"
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::TimeoutError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_wraps_socket_error_as_connection_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          raise SocketError, "dns failed"
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    assert_raises(SimpleInference::ConnectionError) do
      protocol.responses_stream(model: "m", input: "Hello").to_a
    end
  end

  def test_responses_stream_raises_http_error_for_non_2xx_json_response
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 400,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ "error" => { "message" => "bad request" } }),
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    err =
      assert_raises(SimpleInference::HTTPError) do
        protocol.responses_stream(model: "m", input: "Hello").to_a
      end

    assert_equal 400, err.status
  end

  def test_stream_emits_tool_call_delta_and_done_events
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":""}}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.delta","item_id":"item_1","output_index":0,"delta":"{\\"text\\":\\"he"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"item_1","output_index":0,"name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"output":[{"type":"function_call","id":"item_1","call_id":"call_1","name":"echo","arguments":"{\\"text\\":\\"hello\\"}"}],"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse

          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    events = protocol.stream(model: "m", input: "Hello").to_a

    tool_delta = events.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDelta) }
    tool_done = events.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDone) }
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }

    refute_nil tool_delta
    refute_nil tool_done
    refute_nil completed
    assert_equal "call_1", tool_delta.call_id
    assert_equal "{\"text\":\"he", tool_delta.delta
    assert_equal "{\"text\":\"hello\"}", tool_done.arguments
    assert_equal "{\"text\":\"hello\"}", completed.result.output_items.first.fetch("arguments")
  end

  # Two IDENTICAL parallel calls (same name, same arguments) must each get
  # their OWN call_id from the completed body — the shape fallback in the
  # stream/body reconciliation used to attribute the first body item's call_id
  # to both, so one call could never be answered with a tool result.
  def test_high_level_streaming_assigns_distinct_call_ids_to_identical_parallel_calls
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":0,"name":"get_time","arguments":"{}"}\n\n)
          sse << %(data: {"type":"response.function_call_arguments.done","item_id":"fc_2","output_index":1,"name":"get_time","arguments":"{}"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"output":[) +
                 %({"type":"function_call","id":"item_a","call_id":"call_a","name":"get_time","arguments":"{}"},) +
                 %({"type":"function_call","id":"item_b","call_id":"call_b","name":"get_time","arguments":"{}"}) +
                 %(],"usage":{"input_tokens":1,"output_tokens":2}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com",
        responses_path: "/v1/responses",
        adapter: adapter,
      )

    result = protocol.responses(model: "m", input: "What time is it, twice?", stream: true)

    call_ids = result.output_items.map { |item| item.fetch("call_id") }
    assert_equal %w[call_a call_b], call_ids,
                 "identical parallel calls must claim distinct body call_ids in order"
  end

  # --- Declared-vocabulary + extra_body contract (the transplant template) ---

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: capturing_responses_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", reasoning_efort: "high")
      end

    assert_includes error.message, "reasoning_efort"
    assert_includes error.message, "extra_body"
  end

  def test_declared_passthrough_options_reach_the_wire
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(model: "m", input: "Hello", temperature: 0.2, previous_response_id: "resp_prev")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 0.2, body.fetch("temperature")
    assert_equal "resp_prev", body.fetch("previous_response_id")
  end

  # include_usage was a silently-dropped kwarg on the high-level responses
  # helper once (declared, never read); it is not a request option at all
  # now, so the spelling raises as unknown instead of vanishing.
  def test_responses_rejects_the_retired_include_usage_option
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses(model: "m", input: "Hello", include_usage: true)
      end

    assert_includes error.message, "include_usage"
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): the lane CONSTRUCTS
  # the input_image.image_url base64 data URL from verified bytes; caller
  # data URIs, URLs, host paths, and provider file ids are loud rejections
  # at the lowering. The old passthrough of caller-supplied carriers is
  # killed drift.

  def test_media_input_bytes_lower_to_the_inline_base64_data_url
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m",
      input: [
        {
          "type" => "message",
          "role" => "user",
          "content" => [
            { "type" => "input_text", "text" => "look" },
            { "type" => "input_image", "image_url" => media, "detail" => "high" },
          ],
        },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    image_part = body.fetch("input").fetch(0).fetch("content").fetch(1)
    assert_equal "data:image/png;base64,#{[PNG_BYTES].pack("m0")}", image_part.fetch("image_url")
    assert_equal "high", image_part.fetch("detail")
  end


  def test_caller_data_uri_image_is_a_loud_rejection_with_zero_io
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(
          model: "m",
          input: [
            { "role" => "user", "content" => [{ "type" => "input_image", "image_url" => "data:image/png;base64,AAAA" }] },
          ]
        )
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_image_is_a_loud_rejection_with_zero_io
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    assert_raises(SimpleInference::ValidationError) do
      protocol.responses_create(
        model: "m",
        input: [
          { "role" => "user", "content" => [{ "type" => "input_image", "image_url" => "https://example.com/cat.png" }] },
        ]
      )
    end
  end

  def test_provider_file_id_image_is_a_loud_rejection_with_zero_io
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(
          model: "m",
          input: [
            { "role" => "user", "content" => [{ "type" => "input_image", "file_id" => "file-abc123" }] },
          ]
        )
      end

    assert_includes error.message, "file id"
  end

  def test_extra_body_merges_string_keyed_wire_fields_verbatim
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m", input: "Hello",
      extra_body: { "service_tier" => "flex", "safety_identifier" => "user-7" }
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "flex", body.fetch("service_tier")
    assert_equal "user-7", body.fetch("safety_identifier")
  end

  def test_extra_body_reaches_the_streaming_wire_body
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call_stream(env)
          @last_request = env
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: "data: [DONE]\n\n" }
        end
      end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_stream(model: "m", input: "Hello", extra_body: { "service_tier" => "flex" }).to_a

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("stream")
    assert_equal "flex", body.fetch("service_tier")
  end

  def test_extra_body_collisions_with_protocol_built_fields_raise
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: capturing_responses_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", temperature: 0.1, extra_body: { "temperature" => 0.9 })
      end

    assert_includes error.message, "temperature"
  end

  def test_extra_body_rejects_symbol_keys
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: capturing_responses_adapter
      )

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.responses_create(model: "m", input: "Hello", extra_body: { service_tier: "flex" })
      end

    assert_includes error.message, "string keys"
  end

  def test_stream_rejects_unknown_options_eagerly_before_consumption
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        raise "adapter should not be reached"
      end
    end.new

    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    assert_raises(SimpleInference::ValidationError) do
      protocol.stream(model: "m", input: "Hello", temprature: 0.2)
    end
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAIResponses.request_option_keys

    assert_includes keys, :reasoning_effort
    assert_includes keys, :response_format
    assert_includes keys, :prompt_cache_key
    assert_includes keys, :service_tier
    assert_includes keys, :verbosity
    # Neither reference's request struct carries these (codex-rs
    # common.rs ResponsesApiRequest, opencode openai-responses.ts):
    # OpenAI caches by prefix + prompt_cache_key, explicit breakpoints
    # are the Anthropic wire's. Nothing produced them; they are gone.
    refute_includes keys, :prompt_cache_breakpoint
    refute_includes keys, :prompt_cache_options
    assert keys.frozen?
  end

  # --- prompt_cache_key / service_tier: forwarded 1:1 onto the same-named
  # wire fields (codex-rs client.rs:876-877; opencode transform.ts:1312).
  # Which key and which tier is the caller's decision, never this lane's. ---

  def test_prompt_cache_key_and_service_tier_lower_one_to_one_to_the_wire
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m", input: "Hello", prompt_cache_key: "conv_123", service_tier: "flex"
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "conv_123", body.fetch("prompt_cache_key")
    assert_equal "flex", body.fetch("service_tier")
  end

  def test_neither_prompt_cache_key_nor_service_tier_is_invented
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(model: "m", input: "Hello")

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "prompt_cache_key"
    refute_includes body, "service_tier"
  end

  # --- verbosity: `text.verbosity` beside `text.format` (codex-rs
  # common.rs TextControls {verbosity, format}; opencode textVerbosity). ---

  def test_verbosity_folds_into_text_without_a_response_format
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(model: "m", input: "Hello", verbosity: "low")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "verbosity" => "low" }, body.fetch("text"))
    refute_includes body, "verbosity"
  end

  def test_verbosity_folds_into_text_beside_the_response_format
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(
      model: "m", input: "Hello", verbosity: "high", response_format: { type: "json_object" }
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "verbosity" => "high", "format" => { "type" => "json_object" } }, body.fetch("text"))
  end

  def test_verbosity_outside_the_wire_vocabulary_is_a_loud_local_rejection
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: unreachable_adapter
      )

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.responses_create(model: "m", input: "Hello", verbosity: "verbose")
    end

    assert_includes error.message, "verbosity"
    assert_includes error.message, "low, medium, high"
  end

  def test_no_text_object_is_invented_without_verbosity_or_format
    adapter = capturing_responses_adapter
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    protocol.responses_create(model: "m", input: "Hello")

    refute_includes JSON.parse(adapter.last_request.fetch(:body)), "text"
  end

  # --- the SERVED tier rides usage (opencode openai-responses.ts:881-884
  # reads event.response.service_tier back): accounting keys on what the
  # provider reports, never on what was asked for. Absent stays absent. ---

  def test_unary_usage_carries_the_served_service_tier
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] }],
                "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
                "service_tier" => "flex",
              }
            ),
          }
        end
      end.new
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    result = protocol.create(model: "m", input: "Hello", service_tier: "flex")

    assert_equal({ "input_tokens" => 1, "output_tokens" => 2, "service_tier" => "flex" }, result.usage)
  end

  def test_streamed_usage_carries_the_served_service_tier
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"hi"}\n\n)
          sse << %(data: {"type":"response.completed","response":{"status":"completed","service_tier":"priority","usage":{"input_tokens":3,"output_tokens":4}}}\n\n)
          sse << "data: [DONE]\n\n"
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    result = protocol.stream(model: "m", input: "Hello").final_result

    assert_equal({ "input_tokens" => 3, "output_tokens" => 4, "service_tier" => "priority" }, result.usage)
  end

  def test_usage_without_a_served_tier_stays_untouched
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] }],
                "usage" => { "input_tokens" => 1, "output_tokens" => 2 },
              }
            ),
          }
        end
      end.new
    protocol =
      SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", responses_path: "/responses", adapter: adapter
      )

    result = protocol.create(model: "m", input: "Hello")

    assert_equal({ "input_tokens" => 1, "output_tokens" => 2 }, result.usage)
  end


  private

  def unreachable_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "adapter should not be reached"
      end

      def call_stream(_env)
        raise "adapter should not be reached"
      end
    end.new
  end

  def failed_terminal_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        sse = +""
        sse << %(data: {"type":"response.output_text.delta","delta":"par"}\n\n)
        sse << %(data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"provider exploded"},"usage":{"input_tokens":7,"output_tokens":0}}}\n\n)
        sse << "data: [DONE]\n\n"

        yield sse
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end

  def incomplete_terminal_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        sse = +""
        sse << %(data: {"type":"response.output_text.delta","delta":"par"}\n\n)
        sse << %(data: {"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"par"}]}],"usage":{"input_tokens":7,"output_tokens":8}}}\n\n)
        sse << "data: [DONE]\n\n"

        yield sse
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end

  def capturing_responses_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            { "output" => [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "hi" }] }] }
          ),
        }
      end
    end.new
  end

  def responses_protocol_answering(body)
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(body) }
      end
    end.new
    SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", adapter: adapter)
  end
end
