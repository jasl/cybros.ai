require "json"
require "test_helper"

# DeepSeek native Responses lane (POST /responses, no /v1 prefix; the
# provider lists `deepseek-flash` and `deepseek-v4-pro` on it — this file
# drives the flash id, the one the 2026-08-09 probe froze).
#
# Every wire body, JSON response, and SSE payload in this file is a
# DETERMINISTIC CONSTRUCTION mirroring the register-frozen probe facts of
# 2026-08-09 (`deepseek_responses.usage.v1` + the DeepSeek reasoning-contract
# row). None of them is a wire capture.
class TestDeepSeekProtocol < Minitest::Test
  MODEL = "deepseek-flash".freeze

  # Register probe numbers: 20 output / 18 reasoning tokens.
  TERMINAL_USAGE = {
    "input_tokens" => 11,
    "input_tokens_details" => { "cached_tokens" => 0 },
    "output_tokens" => 20,
    "output_tokens_details" => { "reasoning_tokens" => 18 },
    "total_tokens" => 31,
  }.freeze


  def test_default_responses_path_has_no_v1_prefix
    # Route fact: POST https://api.deepseek.com/responses — the /v1-prefixed
    # OpenAI default must never leak into this lane.
    protocol =
      SimpleInference::Protocols::DeepSeekResponses.new(
        base_url: "http://example.com",
        adapter: unreachable_adapter,
      )

    compiled = protocol.compile_create(model: MODEL, input: "Hi")

    assert_equal "/responses", compiled.path
  end

  def test_profile_wire_options_responses_path_is_honored
    protocol =
      SimpleInference::Protocols::DeepSeekResponses.new(
        base_url: "http://example.com",
        responses_path: "/responses",
        adapter: unreachable_adapter,
      )

    compiled = protocol.compile_create(model: MODEL, input: "Hi")

    assert_equal "/responses", compiled.path
  end

  # --- reasoning.effort: verbatim closed 7-value set, no clamping/mapping ---

  def test_all_seven_effort_values_pass_through_verbatim
    %w[none minimal low medium high xhigh max].each do |effort|
      protocol = build_protocol(adapter: unreachable_adapter)

      compiled = protocol.compile_create(model: MODEL, input: "Hi", reasoning_effort: effort)
      body = JSON.parse(compiled.payload)

      assert_equal({ "effort" => effort }, body.fetch("reasoning"), "effort #{effort} must pass through verbatim")
      refute_includes body, "reasoning_effort"
      refute_includes body, "thinking", "there is NO thinking.type toggle on the DeepSeek Responses route"
      refute_includes body, "store"
      refute_includes body, "include"
    end
  end

  def test_none_effort_is_not_remapped_to_a_thinking_toggle
    # On this route "none" is itself the wire value that disables thinking.
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: MODEL, input: "Hi", reasoning_effort: "none")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "effort" => "none" }, body.fetch("reasoning"))
    refute_includes body, "thinking"
  end

  def test_omitted_effort_sends_no_reasoning_field_because_thinking_is_default_on
    # Register: thinking is ON by default on this route; an absent effort is
    # a valid request and must not fabricate a reasoning field.
    protocol = build_protocol(adapter: unreachable_adapter)

    compiled = protocol.compile_create(model: MODEL, input: "Hi")

    refute_includes JSON.parse(compiled.payload), "reasoning"
  end

  def test_out_of_set_effort_is_rejected_locally_with_zero_outbound_io
    ["ultra", "MEDIUM", "", 3].each do |effort|
      protocol = build_protocol(adapter: unreachable_adapter)

      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: MODEL, input: "Hi", reasoning_effort: effort)
        end

      assert_includes error.message, "none|minimal|low|medium|high|xhigh|max"
    end
  end

  def test_reasoning_hash_effort_is_validated_against_the_closed_set
    protocol = build_protocol(adapter: unreachable_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.compile_create(model: MODEL, input: "Hi", reasoning: { effort: "extreme" })
      end

    assert_includes error.message, "none|minimal|low|medium|high|xhigh|max"
  end

  def test_reasoning_summary_is_rejected_locally_because_it_is_never_generated
    # Register: reasoning.summary is accepted but never generated on this
    # route — a control whose effect cannot be observed is a local rejection.
    protocol = build_protocol(adapter: unreachable_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.compile_create(
          model: MODEL,
          input: "Hi",
          reasoning: { effort: "low", summary: "auto" },
        )
      end

    assert_includes error.message, "summary"
  end

  def test_no_openai_stateless_cot_capture_defaults_are_applied
    # The OpenAI archetype adds store:false + include:reasoning.encrypted_content
    # when reasoning is requested. DeepSeek silently ignores store and does not
    # support encrypted_content, so neither may appear on this wire.
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: MODEL, input: "Hi", reasoning_effort: "high")

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "store"
    refute_includes body, "include"
    refute_includes body.fetch("reasoning"), "summary"
  end

  # --- structurally stateless: silently-ignored wire controls are local rejections ---

  def test_silently_ignored_stateless_controls_are_rejected_locally
    {
      previous_response_id: "resp_0",
      conversation: "conv_1",
      store: false,
      include: ["reasoning.encrypted_content"],
      parallel_tool_calls: false,
      reasoning_summary: "auto",
      thinking: { type: "disabled" },
    }.each do |key, value|
      protocol = build_protocol(adapter: unreachable_adapter)

      error =
        assert_raises(SimpleInference::ValidationError, "#{key} must be a loud local rejection") do
          protocol.create(model: MODEL, input: "Hi", key => value)
        end

      assert_includes error.message, key.to_s
      assert_includes error.message, "extra_body"
    end
  end

  def test_request_option_keys_expose_the_closed_lane_vocabulary
    keys = SimpleInference::Protocols::DeepSeekResponses.request_option_keys

    assert keys.frozen?
    assert_includes keys, :reasoning_effort
    assert_includes keys, :reasoning
    assert_includes keys, :tools
    assert_includes keys, :response_format
    refute_includes keys, :thinking
    refute_includes keys, :store
    refute_includes keys, :include
    refute_includes keys, :previous_response_id
    refute_includes keys, :conversation
    refute_includes keys, :parallel_tool_calls
    refute_includes keys, :reasoning_summary
  end

  # --- wire lowering mirrors the Responses archetype where shapes match ---

  def test_function_tools_lower_to_the_flat_responses_shape
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(
      model: MODEL,
      input: "Use the lookup tool.",
      tools: [
        {
          type: "function",
          function: {
            name: "lookup",
            description: "Look up current information.",
            parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
            strict: true,
          },
        },
      ],
      tool_choice: "auto",
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      [
        {
          "type" => "function",
          "name" => "lookup",
          "description" => "Look up current information.",
          "parameters" => {
            "type" => "object",
            "properties" => { "query" => { "type" => "string" } },
            "required" => ["query"],
          },
          "strict" => true,
        },
      ],
      body.fetch("tools")
    )
    assert_equal "auto", body.fetch("tool_choice")
  end

  def test_response_format_lowers_to_text_format
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: MODEL, input: "Hi", response_format: { type: "json_object" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "response_format"
    assert_equal({ "format" => { "type" => "json_object" } }, body.fetch("text"))
  end

  def test_extra_body_merges_string_keyed_wire_fields_verbatim
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: MODEL, input: "Hi", extra_body: { "verbosity" => "low" })

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "low", body.fetch("verbosity")
  end

  def test_stream_surfaces_typed_reasoning_and_text_deltas
    adapter = taxonomy_stream_adapter
    protocol = build_protocol(adapter: adapter)

    events = protocol.stream(model: MODEL, input: "Hi", reasoning_effort: "low").to_a

    assert_equal(
      [
        SimpleInference::Responses::Events::ReasoningDelta,
        SimpleInference::Responses::Events::ReasoningDelta,
        SimpleInference::Responses::Events::TextDelta,
        SimpleInference::Responses::Events::TextDelta,
        SimpleInference::Responses::Events::Completed,
      ],
      events.map(&:class)
    )

    text_events = events.grep(SimpleInference::Responses::Events::TextDelta)
    assert_equal ["Hel", "lo"], text_events.map(&:delta)

    reasoning_events = events.grep(SimpleInference::Responses::Events::ReasoningDelta)
    assert_equal(
      ["Think ", "first."],
      reasoning_events.map(&:delta)
    )
    assert_equal ["reasoning_text", "reasoning_text"], reasoning_events.map(&:kind)
    assert_equal ["rs_1", "rs_1"], reasoning_events.map(&:item_id)

    result = events.last.result
    assert_equal "Hello", result.output_text
    assert_equal TERMINAL_USAGE, result.usage
  end

  def test_stream_usage_is_terminal_only_and_never_fabricated_before_completion
    adapter = taxonomy_stream_adapter
    protocol = build_protocol(adapter: adapter)

    usage_snapshots = []
    result =
      protocol.responses(model: MODEL, input: "Hi", stream: true) do |_delta|
        usage_snapshots << :delta_seen
      end

    # Only the terminal response.completed event carried usage; the parsed
    # result holds it verbatim (presence-vs-zero preserved: cached_tokens 0
    # stays 0, reasoning_tokens 18 stays 18).
    assert_equal [:delta_seen, :delta_seen], usage_snapshots
    assert_equal TERMINAL_USAGE, result.usage
  end

  def test_nonstream_create_keeps_the_provider_usage_hash_verbatim
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: MODEL, input: "Hi", reasoning_effort: "low")

    assert_equal "Hello!", result.output_text
    assert_equal "reasoning", result.output_items.fetch(0).fetch("type")
    assert_equal TERMINAL_USAGE, result.usage
  end

  def test_absent_usage_fields_stay_absent_rather_than_becoming_zero
    # Deterministic construction: a terminal usage without the details
    # sub-objects. A field absent on the wire must stay absent.
    sparse_usage = { "input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6 }
    adapter = recording_json_adapter(usage: sparse_usage)
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: MODEL, input: "Hi")

    assert_equal sparse_usage, result.usage
    refute_includes result.usage, "input_tokens_details"
    refute_includes result.usage, "output_tokens_details"
  end

  # --- interruption + failure terminals (deterministic constructions) ---

  def test_stream_interruption_without_completed_terminal_raises
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}\n\n)
          sse << %(data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"par"}\n\n)
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol = build_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::Error) do
        protocol.responses(model: MODEL, input: "Hi", stream: true)
      end

    assert_includes error.message, "ended before a terminal event"
  end

  def test_response_failed_terminal_raises_with_provider_diagnostics
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.failed","response":{"status":"failed","error":{"code":"invalid_request_error","message":"deterministic construction"}}}\n\n)
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol = build_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::Error) do
        protocol.responses(model: MODEL, input: "Hi", stream: true)
      end

    assert_includes error.message, "invalid_request_error"
    assert_includes error.message, "deterministic construction"
  end

  # --- no hidden retries: exactly one adapter call per request ---

  def test_create_makes_exactly_one_adapter_call
    adapter = recording_json_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: MODEL, input: "Hi")

    assert_equal 1, adapter.calls
  end

  def test_stream_makes_exactly_one_adapter_call
    adapter = taxonomy_stream_adapter
    protocol = build_protocol(adapter: adapter)

    protocol.stream(model: MODEL, input: "Hi").to_a

    assert_equal 1, adapter.calls
  end

  def test_http_error_is_raised_without_a_retry
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :calls

        def initialize
          @calls = 0
          super
        end

        def call(_env)
          @calls += 1
          {
            status: 500,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ "error" => { "message" => "deterministic construction: server_error" } }),
          }
        end
      end.new
    protocol = build_protocol(adapter: adapter)

    assert_raises(SimpleInference::HTTPError) do
      protocol.create(model: MODEL, input: "Hi")
    end

    assert_equal 1, adapter.calls
  end

  private

  def build_protocol(adapter:)
    SimpleInference::Protocols::DeepSeekResponses.new(
      base_url: "http://example.com",
      responses_path: "/responses",
      adapter: adapter,
    )
  end

  def unreachable_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        raise "adapter must not be reached"
      end

      def call_stream(_env)
        raise "adapter must not be reached"
      end
    end.new
  end

  # Non-streaming Responses-shaped body (deterministic construction).
  def recording_json_adapter(usage: TERMINAL_USAGE)
    response_body = {
      "id" => "resp_1",
      "object" => "response",
      "status" => "completed",
      "output" => [
        {
          "type" => "reasoning",
          "id" => "rs_1",
          "content" => [{ "type" => "reasoning_text", "text" => "Consider." }],
        },
        {
          "type" => "message",
          "id" => "msg_1",
          "role" => "assistant",
          "content" => [{ "type" => "output_text", "text" => "Hello!" }],
        },
      ],
      "usage" => usage,
    }

    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request, :calls

      def initialize(body)
        @body = body
        @calls = 0
        super()
      end

      def call(env)
        @calls += 1
        @last_request = env
        { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(@body) }
      end
    end.new(response_body)
  end

  # The full probed SSE taxonomy in register order (deterministic construction).
  def taxonomy_stream_adapter
    usage_json = JSON.generate(TERMINAL_USAGE)
    sse = +""
    sse << %(data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}\n\n)
    sse << %(data: {"type":"response.in_progress","response":{"id":"resp_1","status":"in_progress"}}\n\n)
    sse << %(data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1"}}\n\n)
    sse << %(data: {"type":"response.content_part.added","item_id":"rs_1","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":""}}\n\n)
    sse << %(data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"Think "}\n\n)
    sse << %(data: {"type":"response.reasoning_text.delta","item_id":"rs_1","delta":"first."}\n\n)
    sse << %(data: {"type":"response.reasoning_text.done","item_id":"rs_1","text":"Think first."}\n\n)
    sse << %(data: {"type":"response.content_part.done","item_id":"rs_1","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":"Think first."}}\n\n)
    sse << %(data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","content":[{"type":"reasoning_text","text":"Think first."}]}}\n\n)
    sse << %(data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant"}}\n\n)
    sse << %(data: {"type":"response.content_part.added","item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}\n\n)
    sse << %(data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"Hel"}\n\n)
    sse << %(data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"lo"}\n\n)
    sse << %(data: {"type":"response.output_text.done","item_id":"msg_1","text":"Hello"}\n\n)
    sse << %(data: {"type":"response.content_part.done","item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":"Hello"}}\n\n)
    sse << %(data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}\n\n)
    sse << %(data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"reasoning","id":"rs_1","content":[{"type":"reasoning_text","text":"Think first."}]},{"type":"message","id":"msg_1","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}],"usage":#{usage_json}}}\n\n)

    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :calls

      def initialize(payload)
        @payload = payload
        @calls = 0
        super()
      end

      def call_stream(_env)
        @calls += 1
        yield @payload
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new(sse)
  end
end
