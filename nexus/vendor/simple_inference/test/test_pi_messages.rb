require "json"
require "test_helper"

class TestPiMessages < Minitest::Test
  class Transport < SimpleInference::HTTPAdapter
    attr_reader :request

    def initialize(events)
      @events = events
    end

    def call_stream(env)
      @request = env
      payload = @events.map { |event| "data: #{JSON.generate(event)}\n\n" }.join
      payload.bytes.each_slice(7) { |bytes| yield bytes.pack("C*") }
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: "" }
    end
  end

  def protocol(events: [], **options)
    @adapter = Transport.new(events)
    SimpleInference::Protocols::PiMessages.new(base_url: "https://example.test", provider_id: "radius",
      api_key: "test-secret", adapter: @adapter, **options)
  end

  def done(reason: "stop")
    { "type" => "done", "reason" => reason, "responseId" => "response-1",
      "usage" => { "input" => 10, "output" => 4, "cacheRead" => 3, "cacheWrite" => 2, "totalTokens" => 19 } }
  end

  def test_request_preserves_transcript_order_tools_and_native_thinking
    input = [
      { role: "system", content: "Initial instructions" },
      { role: "user", content: "Question" },
      { role: "assistant", content: [{ type: "thinking", thinking: "Plan", thinkingSignature: "opaque" },
        { type: "text", text: "Working" }] },
      { type: "function_call", call_id: "call-1", name: "read", arguments: '{"path":"note"}' },
      { type: "function_call_output", call_id: "call-1", output: "contents" },
      { role: "system", content: "Later instructions" },
    ]
    compiled = protocol.compile_stream(model: "some-model", input: input, reasoning_effort: "high",
      max_output_tokens: 3000, temperature: 0.3,
      tools: [{ type: "function", name: "read", description: "Read", parameters: { type: "object" } }],
      tool_choice: { type: "function", name: "read" })
    body = JSON.parse(compiled.payload)
    messages = body.fetch("context").fetch("messages")
    assert_equal %w[system system user assistant toolResult system], messages.map { |message| message.fetch("role") }
    assert_equal "read", messages.first.fetch("toolsAdded").first.fetch("name")
    assistant = messages.fetch(3)
    assert_equal %w[pi-messages radius some-model], assistant.values_at("api", "provider", "model")
    assert_equal %w[thinking text toolCall], assistant.fetch("content").map { |part| part.fetch("type") }
    assert_equal "opaque", assistant.dig("content", 0, "thinkingSignature")
    assert_equal({ "path" => "note" }, assistant.dig("content", 2, "arguments"))
    assert_equal ["call-1", "read", false], messages.fetch(4).values_at("toolCallId", "toolName", "isError")
    assert_equal({ "reasoning" => "high", "maxTokens" => 3000, "temperature" => 0.3,
      "toolChoice" => { "type" => "function", "function" => { "name" => "read" } } }, body.fetch("options"))
    refute_includes compiled.payload, "test-secret"
  end

  def test_stream_normalizes_fragmented_text_reasoning_tools_and_usage
    events = [
      { type: "start" }, { type: "thinking_start", contentIndex: 0 },
      { type: "thinking_delta", contentIndex: 0, delta: "计划" },
      { type: "thinking_end", contentIndex: 0, content: "计划", contentSignature: "sig" },
      { type: "text_start", contentIndex: 1 }, { type: "text_delta", contentIndex: 1, delta: "Hello" },
      { type: "text_end", contentIndex: 1, content: "Hello", contentSignature: "text-sig" },
      { type: "toolcall_start", contentIndex: 2, id: "call-1", toolName: "read" },
      { type: "toolcall_delta", contentIndex: 2, delta: '{"path":' },
      { type: "toolcall_delta", contentIndex: 2, delta: '"note"}' },
      { type: "toolcall_end", contentIndex: 2, toolCall: { type: "toolCall", id: "call-1", name: "read", arguments: { path: "note" } } },
      done(reason: "toolUse"),
    ]
    stream = protocol(events: events).stream(model: "m", input: "Hi")
    output = stream.to_a
    result = stream.final_result
    assert_equal "Hello", result.output_text
    assert_equal "计划", result.output_items.first.fetch("text")
    assert_equal "sig", result.output_items.first.dig("provider_payload", "thinkingSignature")
    assert_equal "text-sig", result.output_items.fetch(1).dig("provider_payload", "textSignature")
    assert_equal 1, result.tool_calls.length
    assert_equal '{"path":"note"}', result.tool_calls.fetch(0).fetch("arguments")
    assert_equal %w[reasoning message function_call], result.output_items.map { |item| item.fetch("type") }
    assert_equal [15, 4, 19], result.usage.values_at("input_tokens", "output_tokens", "total_tokens")
    assert_equal "toolUse", result.finish_detail
    assert_equal 1, output.count { |event| event.type == "response.function_call_arguments.done" }
    assert_equal 1, output.count { |event| event.type == "response.completed" }
    assert_equal "https://example.test/messages", @adapter.request.fetch(:url)
    assert_equal "Bearer test-secret", @adapter.request.fetch(:headers).fetch("Authorization")
  end

  def test_unary_entry_point_collects_the_same_stream_and_preserves_redacted_thinking
    events = [{ type: "start" }, { type: "thinking_start", contentIndex: 0 },
      { type: "thinking_end", contentIndex: 0, content: "[redacted]", contentSignature: "opaque", redacted: true },
      done(reason: "length")]
    result = protocol(events: events).create(model: "m", input: "Hi")
    assert_equal "length", result.finish_detail
    assert_equal({ "type" => "thinking", "thinking" => "[redacted]", "thinkingSignature" => "opaque", "redacted" => true },
      result.output_items.fetch(0).fetch("provider_payload"))
    assert_equal 1, result.output_items.length
    refute_includes result.output_items.fetch(0), "text"
  end

  def test_cut_tool_arguments_replay_as_an_empty_object_beside_the_error_result
    call = { type: "function_call", call_id: "cut-call", name: "read", arguments: '{"path":' }
    body = JSON.parse(protocol.compile_create(model: "m", input: [call,
      { type: "function_call_output", call_id: "cut-call", output: "invalid_tool_arguments", is_error: true },
    ]).payload)
    messages = body.fetch("context").fetch("messages")
    assert_equal({}, messages.first.dig("content", 0, "arguments"))
    assert_equal "cut-call", messages.first.dig("content", 0, "id")
    assert_equal "cut-call", messages.last.fetch("toolCallId")
    assert_equal true, messages.last.fetch("isError")
    assert_equal "invalid_tool_arguments", messages.last.dig("content", 0, "text")
    assert_equal '{"path":', call.fetch(:arguments), "replay must not repair the stored invalid call"
  end

  def test_disabled_reasoning_omits_the_effort_as_in_the_pi_off_request
    [{}, { reasoning_enabled: false, reasoning_effort: "high" }, { reasoning_effort: "none" }].each do |options|
      body = JSON.parse(protocol.compile_create(model: "m", input: "Hi", **options).payload)
      refute body.fetch("options").key?("reasoning")
    end
    active = JSON.parse(protocol.compile_create(model: "m", input: "Hi",
      reasoning_enabled: true, reasoning_effort: "high").payload)
    assert_equal "high", active.dig("options", "reasoning")
  end

  def test_signature_only_and_redacted_thinking_round_trip_as_native_parts
    native = [
      { "type" => "thinking", "thinking" => "", "thinkingSignature" => "signature-only" },
      { "type" => "thinking", "thinking" => "[redacted]", "thinkingSignature" => "opaque", "redacted" => true },
    ]
    events = [{ type: "start" }]
    native.each_with_index do |part, index|
      events << { type: "thinking_start", contentIndex: index }
      events << { type: "thinking_end", contentIndex: index, content: part.fetch("thinking"),
        contentSignature: part.fetch("thinkingSignature"), redacted: part["redacted"] }
    end
    result = protocol(events: events + [done]).create(model: "m", input: "Hi")
    payloads = result.output_items.map { |item| item.fetch("provider_payload") }
    assert_equal native, payloads
    assert_equal "signature-only", result.output_items.first.fetch("signature")
    assert_empty result.output_items.first.fetch("text")
    refute result.output_items.last.key?("text")
    replay = JSON.parse(protocol.compile_create(model: "m", input: [
      { role: "assistant", content: payloads }, { role: "user", content: "Continue" },
    ]).payload)
    assert_equal native, replay.dig("context", "messages", 0, "content")
  end

  def test_missing_terminal_and_unfinished_tool_are_interruptions
    assert_raises(SimpleInference::ProviderStreamInterruptedError) do
      protocol(events: [{ type: "start" }]).create(model: "m", input: "Hi")
    end
    assert_raises(SimpleInference::ProviderStreamInterruptedError) do
      protocol(events: [{ type: "start" }, { type: "toolcall_start", contentIndex: 0, id: "c", toolName: "read" }, done])
        .create(model: "m", input: "Hi")
    end
    assert_raises(SimpleInference::DecodeError) do
      protocol(events: [done]).create(model: "m", input: "Hi")
    end
  end

  def test_provider_error_never_publishes_a_successful_partial_result
    error = assert_raises(SimpleInference::StreamError) do
      protocol(events: [{ type: "error", reason: "error", errorMessage: "upstream unavailable" }])
        .create(model: "m", input: "Hi")
    end
    assert_equal "upstream unavailable", error.message
  end

  def test_consumer_break_keeps_partial_text_without_a_completed_result
    stream = protocol(events: [{ type: "start" }, { type: "text_start", contentIndex: 0 },
      { type: "text_delta", contentIndex: 0, delta: "partial" }, done]).stream(model: "m", input: "Hi")
    stream.each { |event| break if event.type == "response.output_text.delta" }
    assert_equal "partial", stream.output_text
    assert_raises(SimpleInference::StreamError) { stream.final_result }
  end

  def test_images_use_verified_bytes_and_pdf_has_no_silent_text_fallback
    media = SimpleInference::MediaInput.from_bytes("\x89PNG\r\n\x1a\nimage".b)
    body = JSON.parse(protocol.compile_stream(model: "m", input: [{ role: "user",
      content: [{ type: "image_url", image_url: { "url" => media } }] }]).payload)
    assert_equal({ "type" => "image", "data" => [media.bytes].pack("m0"), "mimeType" => "image/png" },
      body.dig("context", "messages", 0, "content", 0))
    assert_raises(SimpleInference::ValidationError) do
      protocol.compile_stream(model: "m", input: [{ role: "user", content: [{ type: "input_file", file_data: media }] }])
    end
  end
end
