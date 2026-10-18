require "json"
require "test_helper"

# The declared-vocabulary + extra_body contract on the CHAT-COMPLETIONS
# family's public surface (OpenAICompatibleResponses — the class the planner
# routes to):
# - create/stream accept ONLY their declared symbol options,
# - provider-specific wire fields ride the extra_body escape hatch
#   (string-keyed, merged verbatim, collisions rejected),
# - the built body exits through the finalize seam on BOTH the JSON and the
#   SSE wire paths (stream:true forcing and stream_options.include_usage
#   injection survive the conversion).
class TestChatCompletionsContract < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  class CapturingChatAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call(env)
      @last_request = env
      {
        status: 200,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(
          {
            id: "chatcmpl_1",
            choices: [
              { message: { role: "assistant", content: "hello" }, finish_reason: "stop" },
            ],
            usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
          }
        ),
      }
    end
  end

  class CapturingStreamAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call_stream(env)
      @last_request = env
      yield %(data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n)
      yield %(data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":3}}\n\n)
      yield "data: [DONE]\n\n"

      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end

  def build_protocol(adapter:)
    SimpleInference::Protocols::OpenAICompatibleResponses.new(base_url: "http://example.com", api_key: "k", adapter: adapter)
  end

  def test_declared_options_reach_the_wire_with_responses_translation
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.create(model: "chat-model", input: "Hello", temperature: 0.2, max_output_tokens: 128)

    assert_instance_of SimpleInference::Responses::Result, result
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "chat-model", body.fetch("model")
    assert_equal 0.2, body.fetch("temperature")
    # The responses-surface option is translated onto the chat wire name.
    assert_equal 128, body.fetch("max_tokens")
    refute_includes body, "max_output_tokens"
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: CapturingChatAdapter.new).create(model: "m", input: "x", temperture: 0.2)
      end

    assert_includes error.message, "temperture"
    assert_includes error.message, "extra_body"
  end

  def test_stream_rejects_unknown_symbol_options_before_any_request
    adapter = CapturingStreamAdapter.new

    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: adapter).stream(model: "m", input: "x", raesoning: {})
      end

    assert_includes error.message, "raesoning"
    assert_includes error.message, "extra_body"
    assert_nil adapter.last_request
  end

  def test_extra_body_merges_string_keyed_fields_verbatim
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(model: "m", input: "x", extra_body: { "safe_prompt" => true, "repetition_penalty" => 1.1 })

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("safe_prompt")
    assert_equal 1.1, body.fetch("repetition_penalty")
  end

  def test_extra_body_rejects_symbol_keys
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: CapturingChatAdapter.new).create(model: "m", input: "x", extra_body: { safe_prompt: true })
      end

    assert_includes error.message, "string keys"
  end

  def test_extra_body_collisions_with_built_wire_fields_raise
    protocol = build_protocol(adapter: CapturingChatAdapter.new)

    model_error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "m", input: "x", extra_body: { "model" => "other" })
      end
    assert_includes model_error.message, "model"

    declared_error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "m", input: "x", temperature: 0.1, extra_body: { "temperature" => 0.9 })
      end
    assert_includes declared_error.message, "temperature"
  end

  def test_stream_merges_extra_body_and_keeps_stream_forcing_and_usage_injection
    adapter = CapturingStreamAdapter.new
    protocol = build_protocol(adapter: adapter)

    result = protocol.stream(model: "m", input: "x", extra_body: { "safe_prompt" => true }).final_result

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("safe_prompt")
    assert_equal true, body.fetch("stream")
    assert_equal true, body.dig("stream_options", "include_usage")
    assert_equal 3, result.usage.fetch("total_tokens")
  end

  # The usage injection is a CONSTRUCTION fact now, not a hidden per-request
  # default: a lane whose provider bills usage without the opt-in constructs
  # with stream_include_usage: false and the field never reaches the wire.
  def test_stream_include_usage_construction_option_false_omits_stream_options
    adapter = CapturingStreamAdapter.new
    protocol = SimpleInference::Protocols::OpenAICompatibleResponses.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter, stream_include_usage: false
    )

    protocol.stream(model: "m", input: "x").final_result

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal true, body.fetch("stream")
    refute body.key?("stream_options")
  end

  def test_stream_include_usage_construction_option_rejects_non_boolean_values
    error =
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Protocols::OpenAICompatibleResponses.new(
          base_url: "http://example.com", api_key: "k", adapter: CapturingChatAdapter.new, stream_include_usage: "yes"
        )
      end

    assert_includes error.message, "stream_include_usage"
  end

  # include_usage was a per-request kwarg once; it is construction data now,
  # so the old spelling must fail loudly instead of silently changing wires.
  def test_stream_rejects_the_retired_include_usage_request_option
    error =
      assert_raises(SimpleInference::ValidationError) do
        build_protocol(adapter: CapturingStreamAdapter.new).stream(model: "m", input: "x", include_usage: true)
      end

    assert_includes error.message, "include_usage"
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): the chat-family
  # translation CONSTRUCTS the image_url.url base64 data URL from verified
  # bytes; caller http(s) URLs, data URIs, host paths, and provider file
  # handles are loud rejections at the lowering. The old caller-carrier
  # passthrough is killed drift.

  def test_media_input_bytes_lower_to_the_base64_data_url_on_the_chat_wire
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(
      model: "m",
      input: [
        {
          "role" => "user",
          "content" => [
            { "type" => "input_text", "text" => "look" },
            { "type" => "input_image", "image_url" => media },
          ],
        },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    image_part = body.fetch("messages").fetch(0).fetch("content").fetch(1)
    assert_equal "image_url", image_part.fetch("type")
    assert_equal(
      "data:image/png;base64,#{[PNG_BYTES].pack("m0")}",
      image_part.fetch("image_url").fetch("url")
    )
  end

  def test_caller_data_uri_image_is_a_loud_rejection_before_any_request
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "m",
          input: [{ "role" => "user", "content" => [{ "type" => "image_url", "image_url" => { "url" => "data:image/png;base64,AAAA" } }] }]
        )
      end

    assert_includes error.message, "MediaInput"
    assert_nil adapter.last_request, "a rejected carrier must never reach the wire"
  end

  def test_caller_remote_url_image_is_a_loud_rejection_before_any_request
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "m",
        input: [{ "role" => "user", "content" => [{ "type" => "input_image", "image_url" => "https://example.com/cat.png" }] }]
      )
    end

    assert_nil adapter.last_request, "a rejected carrier must never reach the wire"
  end

  # --- streaming honesty: no hidden second POST, no synthesized streams ---

  class NonStreamingJSONAdapter < SimpleInference::HTTPAdapter
    attr_reader :post_count, :stream_count

    def initialize(status: 200, body: nil)
      @status = status
      @body = body
      @post_count = 0
      @stream_count = 0
    end

    def call(_env)
      @post_count += 1
      json_response
    end

    def call_stream(_env)
      @stream_count += 1
      json_response
    end

    private

    def json_response
      {
        status: @status,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(@body || { "choices" => [{ "message" => { "role" => "assistant", "content" => "hi" } }] }),
      }
    end
  end

  # Deterministic construction: a gateway that answers a stream request with
  # a buffered JSON success. Streaming support is a profile capability fact —
  # discovering it at runtime (and silently synthesizing a stream) is gone.
  def test_stream_request_answered_with_non_sse_success_is_a_typed_error
    adapter = NonStreamingJSONAdapter.new
    protocol = SimpleInference::Protocols::OpenRouterResponses.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter,
      stream_include_usage: false
    )

    error =
      assert_raises(SimpleInference::ProviderStreamInterruptedError) do
        protocol.stream(model: "m", input: "x").final_result
      end

    assert_includes error.message, "non-SSE"
    assert_equal 0, error.events_seen
    assert_equal 1, adapter.stream_count
    assert_equal 0, adapter.post_count, "the hidden fallback POST is deleted"
  end

  # Deterministic construction of the old fallback trigger body: the exact
  # error string no longer selects a hidden second POST — it is an ordinary
  # HTTP error now.
  def test_streaming_unsupported_error_body_no_longer_triggers_a_fallback_post
    adapter = NonStreamingJSONAdapter.new(status: 400, body: { "detail" => "Streaming responses are not supported yet" })
    protocol = build_protocol(adapter: adapter)

    assert_raises(SimpleInference::HTTPError) do
      protocol.stream(model: "m", input: "x").final_result
    end
    assert_equal 1, adapter.stream_count
    assert_equal 0, adapter.post_count, "the hidden fallback POST is deleted"
  end

  # Deterministic construction: a mid-stream data event carrying a top-level
  # error object under HTTP 200 is a typed loud failure, never ride-through.
  def test_mid_stream_top_level_error_event_raises_a_typed_error
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n)
        yield %(data: {"error":{"code":500,"message":"midstream failure"}}\n\n)
        yield "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = build_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::HTTPError) do
        protocol.stream(model: "m", input: "x").final_result
      end

    assert_equal 500, error.status
    assert_includes error.message, "midstream failure"
  end


  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::OpenAICompatibleResponses.request_option_keys

    assert_includes keys, :instructions
    assert_includes keys, :max_output_tokens
    assert_includes keys, :reasoning_effort
    assert keys.frozen?
  end

  # The kernel splices prior-round tool calls into the input in its canonical
  # flat shape ({"id","name","arguments"}). Chat-completions wire requires the
  # nested function envelope with a "type" tag — DeepSeek's strict parser 400s
  # without it ("messages[2]: missing field `type`"), while lenient gateways
  # (OpenRouter) happen to accept the flat form.
  def test_create_normalizes_kernel_tool_call_splice_to_chat_wire
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(
      model: "m",
      instructions: "sys",
      input: [
        { "role" => "user", "content" => [{ "type" => "input_text", "text" => "fix it" }] },
        {
          "role" => "assistant",
          "content" => "on it",
          "tool_calls" => [{ "id" => "call_1", "name" => "bash", "arguments" => "{\"command\":\"ls\"}" }],
        },
        { "role" => "tool", "tool_call_id" => "call_1", "name" => "bash", "content" => "README.md" },
      ],
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assistant = messages.fetch(2)
    call = assistant.fetch("tool_calls").fetch(0)
    assert_equal "call_1", call.fetch("id")
    assert_equal "function", call.fetch("type")
    assert_equal "bash", call.dig("function", "name")
    assert_equal "{\"command\":\"ls\"}", call.dig("function", "arguments")
    refute call.key?("name"), "flat canonical fields must not leak beside the envelope"

    tool = messages.fetch(3)
    assert_equal "tool", tool.fetch("role")
    assert_equal "call_1", tool.fetch("tool_call_id")
    assert_equal "README.md", tool.fetch("content")
  end

  def test_create_passes_chat_shaped_tool_calls_through_and_stringifies_arguments
    adapter = CapturingChatAdapter.new
    protocol = build_protocol(adapter: adapter)

    protocol.create(
      model: "m",
      input: [
        {
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            { "id" => "call_2", "type" => "function", "function" => { "name" => "zap", "arguments" => { "x" => 1 } } },
          ],
        },
        { "role" => "tool", "tool_call_id" => "call_2", "content" => "done" },
      ],
    )

    call = JSON.parse(adapter.last_request.fetch(:body)).dig("messages", 0, "tool_calls", 0)
    assert_equal "call_2", call.fetch("id")
    assert_equal "function", call.fetch("type")
    assert_equal "zap", call.dig("function", "name")
    assert_equal "{\"x\":1}", call.dig("function", "arguments"), "hash arguments serialize to a JSON string"
  end
  # THE TOOL LOOP'S SECOND ROUND. A caller splicing a prior round hands
  # this family Responses-style `function_call` / `function_call_output`
  # ITEMS — the shape every other protocol here translates. This one
  # passed them through untouched, so they reached the wire with no
  # `role` at all and the endpoint dropped or refused them: the model
  # called a tool, the result came back, and the model never saw it.
  def test_responses_tool_items_lower_onto_the_chat_wire
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "role" => "user", "content" => "read a.rb" },
        { "type" => "function_call", "call_id" => "call_1", "name" => "read_file",
          "arguments" => { "path" => "a.rb" } },
        { "type" => "function_call_output", "call_id" => "call_1", "name" => "read_file",
          "output" => "contents of a" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[user assistant tool], messages.map { |m| m["role"] },
      "every message reaches the wire with a role"

    call = messages[1].fetch("tool_calls").first
    assert_equal "call_1", call.fetch("id")
    assert_equal "function", call.fetch("type")
    assert_equal "read_file", call.dig("function", "name")
    assert_equal({ "path" => "a.rb" }, JSON.parse(call.dig("function", "arguments")),
      "arguments ride as a JSON string, as this wire requires")

    assert_equal "call_1", messages[2].fetch("tool_call_id")
    assert_equal "contents of a", messages[2].fetch("content")
  end

  # ONE ROUND, ONE ASSISTANT MESSAGE. A round of N calls is N
  # `function_call` items in the kernel's spelling; the chat wire says
  # the same thing as one assistant message whose `tool_calls` carries
  # every call, followed by the N tool messages. Split into N assistant
  # messages, a strict endpoint (Kimi K3 on OpenRouter) refuses the NEXT
  # round: "tool messages need a preceding assistant tool call".
  def test_a_rounds_calls_ride_one_assistant_message
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "role" => "user", "content" => "read both" },
        { "type" => "function_call", "call_id" => "call_1", "name" => "read_file",
          "arguments" => { "path" => "a.rb" } },
        { "type" => "function_call", "call_id" => "call_2", "name" => "read_file",
          "arguments" => { "path" => "b.rb" } },
        { "type" => "function_call_output", "call_id" => "call_1", "output" => "contents of a" },
        { "type" => "function_call_output", "call_id" => "call_2", "output" => "contents of b" },
        { "type" => "function_call", "call_id" => "call_3", "name" => "edit_file",
          "arguments" => { "path" => "a.rb" } },
        { "type" => "function_call_output", "call_id" => "call_3", "output" => "edited" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[user assistant tool tool assistant tool], messages.map { |m| m["role"] },
      "two calls of one round are ONE assistant message; the next round is its own"

    assert_equal %w[call_1 call_2], messages[1].fetch("tool_calls").map { |c| c["id"] }
    assert_nil messages[1].fetch("content")
    assert_equal %w[call_1 call_2], messages[2..3].map { |m| m.fetch("tool_call_id") }
    assert_equal ["call_3"], messages[4].fetch("tool_calls").map { |c| c["id"] }
    assert_equal "call_3", messages[5].fetch("tool_call_id")
  end

  # The round's own words come BEFORE its calls in the kernel's order, as
  # an assistant message of their own; on this wire they are the same
  # message's `content`, and whatever else that message carried (a
  # reasoning echo, say) rides once.
  def test_the_rounds_text_rides_the_same_message_as_its_calls
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "role" => "user", "content" => "read both" },
        { "role" => "assistant", "content" => "Reading both files.",
          "reasoning_details" => [{ "type" => "reasoning.text", "text" => "two reads" }] },
        { "type" => "function_call", "call_id" => "call_1", "name" => "read_file",
          "arguments" => { "path" => "a.rb" } },
        { "type" => "function_call", "call_id" => "call_2", "name" => "read_file",
          "arguments" => { "path" => "b.rb" } },
        { "type" => "function_call_output", "call_id" => "call_1", "output" => "contents of a" },
        { "type" => "function_call_output", "call_id" => "call_2", "output" => "contents of b" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[user assistant tool tool], messages.map { |m| m["role"] }
    assert_equal "Reading both files.", messages[1].fetch("content")
    assert_equal %w[call_1 call_2], messages[1].fetch("tool_calls").map { |c| c["id"] }
    assert_equal [{ "type" => "reasoning.text", "text" => "two reads" }],
      messages[1].fetch("reasoning_details"), "the round's reasoning echo rides once"
  end

  # The rule's other half: an ASSISTANT message directly after the message
  # carrying the round's calls — words the model said between two calls,
  # or the fence a reasoning item it thought there became — is the same
  # round's, so it folds into that one message's content and the next call
  # keeps folding there. Lowered as its own message it split the round's
  # calls across two assistant messages, and a strict endpoint refused
  # the tool message that followed the second. A tool message still never
  # folds, so a later round's words stay its own message.
  def test_an_assistant_message_after_a_call_folds_into_the_rounds_one_message
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "role" => "user", "content" => "read both" },
        { "role" => "assistant", "content" => "M" },
        { "type" => "function_call", "call_id" => "call_x", "name" => "read_file",
          "arguments" => { "path" => "a.rb" } },
        { "role" => "assistant", "content" => [{ "type" => "input_text", "text" => "<think>b</think>" }] },
        { "type" => "function_call", "call_id" => "call_y", "name" => "read_file",
          "arguments" => { "path" => "b.rb" } },
        { "type" => "function_call_output", "call_id" => "call_x", "output" => "a" },
        { "type" => "function_call_output", "call_id" => "call_y", "output" => "b" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[user assistant tool tool], messages.map { |m| m["role"] },
      "one round, one assistant message, every tool message after it"
    assert_equal [{ "type" => "text", "text" => "M" }, { "type" => "text", "text" => "<think>b</think>" }],
      messages[1].fetch("content"), "both messages' words, in order, as one part list"
    assert_equal %w[call_x call_y], messages[1].fetch("tool_calls").map { |c| c["id"] }
    assert_equal %w[call_x call_y], messages[2..3].map { |m| m.fetch("tool_call_id") }

    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "role" => "assistant", "content" => "A" },
        { "type" => "function_call", "call_id" => "call_x", "name" => "a", "arguments" => {} },
        { "type" => "function_call_output", "call_id" => "call_x", "output" => "1" },
        { "role" => "assistant", "content" => "B" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[assistant tool assistant], messages.map { |m| m["role"] },
      "a tool message never folds: the next round's words are its own message"
    assert_equal %w[A B], messages.values_at(0, 2).map { |m| m.fetch("content") }
  end

  # A tool result never folds: it is the NEXT speaker, and a call after it
  # opens a new assistant message.
  def test_a_tool_result_between_calls_keeps_the_rounds_apart
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [
        { "type" => "function_call", "call_id" => "call_1", "name" => "a", "arguments" => {} },
        { "type" => "function_call_output", "call_id" => "call_1", "output" => "1" },
        { "type" => "function_call", "call_id" => "call_2", "name" => "b", "arguments" => {} },
        { "type" => "function_call_output", "call_id" => "call_2", "output" => "2" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal %w[assistant tool assistant tool], messages.map { |m| m["role"] }
    assert_equal [["call_1"], ["call_2"]],
      messages.values_at(0, 2).map { |m| m.fetch("tool_calls").map { |c| c["id"] } }
  end

  # A structured output is serialized rather than dropped: the model
  # reading it is the only reason the round continues.
  def test_a_structured_tool_output_is_serialized_not_dropped
    adapter = CapturingChatAdapter.new
    build_protocol(adapter: adapter).create(
      model: "m",
      input: [{ "type" => "function_call_output", "call_id" => "c",
                "output" => { "ok" => true } }]
    )

    message = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").first
    assert_equal "tool", message.fetch("role")
    assert_equal({ "ok" => true }, JSON.parse(message.fetch("content")))
  end

  # --- the refusal: a typed fact on both chat lanes, never the answer ---

  CHAT_LANES = [
    SimpleInference::Protocols::OpenAICompatibleResponses,
    SimpleInference::Protocols::OpenRouterResponses,
  ].freeze

  # `message.refusal` is the model declining: the finish is typed
  # "refusal" (the wire's finish_reason says only "stop"), the sentence
  # rides Result#refusal, and it never merges into the content.
  def test_a_refusal_message_is_a_typed_refusal_and_never_the_content
    CHAT_LANES.each do |lane|
      result = chat_lane(lane, answering: {
        "id" => "chat_r", "object" => "chat.completion",
        "choices" => [{ "index" => 0, "finish_reason" => "stop",
                        "message" => { "role" => "assistant", "content" => nil, "refusal" => "I can't help with that." } }],
        "usage" => CHAT_USAGE,
      }).create(model: "m", input: "hi")

      assert_equal "refusal", result.finish_detail, lane.name
      assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: "I can't help with that."),
        result.refusal, lane.name
      assert_equal "", result.output_text, lane.name
      assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "openai_compatible_chat", detail: result.finish_detail)
    end
  end

  def test_a_content_filter_finish_is_a_typed_refusal_with_no_invented_details
    CHAT_LANES.each do |lane|
      result = chat_lane(lane, answering: {
        "id" => "chat_f", "object" => "chat.completion",
        "choices" => [{ "index" => 0, "finish_reason" => "content_filter",
                        "message" => { "role" => "assistant", "content" => "" } }],
        "usage" => CHAT_USAGE,
      }).create(model: "m", input: "hi")

      assert_equal "content_filter", result.finish_detail, lane.name
      assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: nil), result.refusal, lane.name
      assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "openrouter_chat", detail: result.finish_detail)
    end
  end

  # A streamed refusal arrives as `delta.refusal`: it folds into the
  # synthesized message's `refusal`, never into the text deltas or content.
  def test_a_streamed_refusal_delta_folds_into_the_refusal_never_the_content
    CHAT_LANES.each do |lane|
      stream = chat_lane(lane, streaming: [
        { "choices" => [{ "index" => 0, "delta" => { "role" => "assistant", "refusal" => "I can't " }, "finish_reason" => nil }] },
        { "choices" => [{ "index" => 0, "delta" => { "refusal" => "help." }, "finish_reason" => nil }] },
        { "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => "stop" }], "usage" => CHAT_USAGE },
      ]).stream(model: "m", input: "hi")
      events = stream.to_a
      result = stream.final_result

      assert_empty events.grep(SimpleInference::Responses::Events::TextDelta), lane.name
      assert_equal "refusal", result.finish_detail, lane.name
      assert_equal "I can't help.", result.refusal.explanation, lane.name
      assert_equal "I can't help.", result.assistant_message.fetch("refusal"), lane.name
      assert_equal "", result.output_text, lane.name
    end
  end

  def test_a_clean_chat_answer_carries_no_refusal
    CHAT_LANES.each do |lane|
      result = chat_lane(lane, answering: {
        "id" => "chat_ok", "object" => "chat.completion",
        "choices" => [{ "index" => 0, "finish_reason" => "stop", "message" => { "role" => "assistant", "content" => "hi" } }],
        "usage" => CHAT_USAGE,
      }).create(model: "m", input: "hi")

      assert_nil result.refusal, lane.name
      assert_equal "stop", result.finish_detail, lane.name
    end
  end

  # OpenRouter's usage carries its own required discriminators; the plain
  # compat lane ignores the extra keys.
  CHAT_USAGE = { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2,
                 "cost" => 0, "is_byok" => false }.freeze

  def chat_lane(lane, answering: nil, streaming: nil)
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(answering) }
      end

      define_method(:call_stream) do |_env, &block|
        streaming.each { |chunk| block.call("data: #{JSON.generate(chunk)}\n\n") }
        block.call("data: [DONE]\n\n")
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    lane.new(base_url: "http://example.com", api_key: "k", adapter: adapter, stream_include_usage: false)
  end
end
