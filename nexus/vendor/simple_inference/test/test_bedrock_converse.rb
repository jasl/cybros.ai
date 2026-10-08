require "test_helper"
require "stringio"
require "socket"
require "simple_inference/http_adapters/httpx"
require "simple_inference/http_adapters/async_http"

class TestBedrockConverse < Minitest::Test
  class Adapter < SimpleInference::HTTPAdapter
    attr_reader :request

    def initialize(chunks: [], body: nil, status: 200)
      @chunks, @body, @status = chunks, body, status
    end

    def call(request)
      @request = request
      { status: @status, headers: { "content-type" => "application/json" }, body: JSON.generate(@body) }
    end

    def call_stream(request)
      @request = request
      return call(request) if @body

      @chunks.each { |chunk| yield chunk }
      { status: @status, headers: { "content-type" => "application/vnd.amazon.eventstream",
                                  "x-amzn-requestid" => "request-123" }, body: nil }
    end
  end

  def test_binary_stream_reassembles_split_frames_text_thinking_and_tool_arguments
    frames = [
      frame("messageStart", { role: "assistant" }),
      frame("contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { text: "Plan" } } }),
      frame("contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { signature: "sig-" } } }),
      frame("contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { signature: "123" } } }),
      frame("contentBlockStop", { contentBlockIndex: 0 }),
      frame("contentBlockDelta", { contentBlockIndex: 1, delta: { text: "你好" } }),
      frame("contentBlockStart", { contentBlockIndex: 2, start: { toolUse: { toolUseId: "call-1", name: "read" } } }),
      frame("contentBlockDelta", { contentBlockIndex: 2, delta: { toolUse: { input: '{"path":' } } }),
      frame("contentBlockDelta", { contentBlockIndex: 2, delta: { toolUse: { input: '"a"}' } } }),
      frame("contentBlockStop", { contentBlockIndex: 2 }),
      frame("messageStop", { stopReason: "tool_use" }),
      frame("metadata", { usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30,
                                   cacheReadInputTokens: 5, cacheWriteInputTokens: 7,
                                   cacheDetails: [{ ttl: "1h", inputTokens: 3 }, { ttl: "5m", inputTokens: 4 }] } }),
    ].join
    adapter = Adapter.new(chunks: frames.bytes.each_slice(11).map { |bytes| bytes.pack("C*") })
    stream = protocol(adapter).stream(model: "vendor.model:1", input: "Hello")
    events = stream.to_a
    result = stream.final_result

    assert_equal "你好", result.output_text
    assert_equal "request-123", result.id
    assert_equal "tool_use", result.finish_reason
    assert_equal ["Plan"], events.grep(SimpleInference::Responses::Events::ReasoningDelta).map(&:delta)
    assert_equal '{"path":"a"}', result.tool_calls.fetch(0).fetch("arguments")
    assert_equal ['{"path":', '"a"}'], events.grep(SimpleInference::Responses::Events::ToolCallDelta).map(&:delta)
    assert_equal '{"path":"a"}', events.grep(SimpleInference::Responses::Events::ToolCallDone).fetch(0).arguments
    assert_equal({ "reasoningContent" => { "reasoningText" => { "text" => "Plan", "signature" => "sig-123" } } },
      result.output_items.fetch(0).fetch("provider_payload"))
    assert_equal 5, result.usage.fetch("cache_read_input_tokens")
    assert_equal 7, result.usage.fetch("cache_creation_input_tokens")
    assert_equal 30, result.usage.fetch("total_tokens")
    assert_equal({ "ephemeral_1h_input_tokens" => 3, "ephemeral_5m_input_tokens" => 4 }, result.usage.fetch("cache_creation"))
    assert_equal "Bearer secret", adapter.request.fetch(:headers).fetch("Authorization")
    assert_equal "application/vnd.amazon.eventstream", adapter.request.fetch(:headers).fetch("Accept")
    assert_equal "https://bedrock.example.test/model/vendor.model%3A1/converse-stream", adapter.request.fetch(:url)
    refute JSON.parse(adapter.request.fetch(:body)).key?("stream")
  end

  def test_signature_only_and_redacted_byte_fragments_replay_without_loss
    native = { "reasoningContent" => { "reasoningText" => { "text" => "", "signature" => "sig-only" } } }
    chunks = [
      frame("contentBlockDelta", { contentBlockIndex: 0, delta: { reasoningContent: { signature: "sig-only" } } }),
      frame("contentBlockDelta", { contentBlockIndex: 1, delta: { reasoningContent: { redactedContent: Base64.strict_encode64("\x00\xFF".b) } } }),
      frame("contentBlockDelta", { contentBlockIndex: 1, delta: { reasoningContent: { redactedContent: Base64.strict_encode64("\x01".b) } } }),
      frame("messageStop", { stopReason: "end_turn" }),
    ]
    result = protocol(Adapter.new(chunks: chunks)).stream(model: "other-vendor", input: "Hello").final_result
    assert_equal native, result.output_items.fetch(0).fetch("provider_payload")
    assert_equal Base64.strict_encode64("\x00\xFF\x01".b), result.output_items.fetch(1).fetch("data")
    assert_equal "", result.output_text

    replay = result.output_items.map { |item| { type: "bedrock_reasoning", provider_payload: item.fetch("provider_payload") } }
    compiled = protocol.compile_stream(model: "other-vendor", input: [
      { role: "user", content: "First" }, { role: "assistant", content: replay }, { role: "user", content: "Next" },
    ])
    assert_equal result.output_items.map { |item| item.fetch("provider_payload") },
      JSON.parse(compiled.payload).fetch("messages").fetch(1).fetch("content")
  end

  def test_request_places_system_history_tool_results_media_and_cache_markers
    image = SimpleInference::MediaInput.new(bytes: "image-bytes", media_type: "image/png")
    pdf = SimpleInference::MediaInput.new(bytes: "%PDF-1.7\n", media_type: "application/pdf")
    compiled = protocol.compile_stream(model: "arn:aws:bedrock:region:123:inference-profile/a", input: [
      { role: "system", content: [{ type: "text", text: "Stable", cache_control: { type: "ephemeral", ttl: "1h" } }] },
      { role: "user", content: "First" },
      { type: "function_call", call_id: "a/b", name: "read", arguments: '{"path":"a"}' },
      { type: "function_call", call_id: "c", name: "read", arguments: "{}" },
      { type: "function_call_output", call_id: "a/b", output: "A" },
      { type: "function_call_output", call_id: "c", output: "failure", is_error: true },
      { role: "assistant", content: "Done" },
      { role: "system", content: "Later" },
      { role: "user", content: [
        { type: "input_image", image_url: image }, { type: "input_file", file_data: pdf, filename: "a.pdf" },
      ] },
    ], max_output_tokens: 50, temperature: 0.2, top_p: 0.8,
      tools: [{ type: "function", name: "read", parameters: { type: "object" }, strict: true }], tool_choice: "required")
    body = JSON.parse(compiled.payload)

    assert_equal [{ "text" => "Stable" }, { "cachePoint" => { "type" => "default", "ttl" => "1h" } }], body.fetch("system")
    messages = body.fetch("messages")
    assert_equal %w[user assistant user assistant user], messages.map { |message| message.fetch("role") }
    assert_equal %w[a_b c], messages.fetch(1).fetch("content").map { |part| part.dig("toolUse", "toolUseId") }
    assert_equal %w[success error], messages.fetch(2).fetch("content").map { |part| part.dig("toolResult", "status") }
    assert_equal "Later", messages.last.fetch("content").fetch(0).fetch("text")
    assert_equal Base64.strict_encode64("image-bytes"), messages.last.dig("content", 1, "image", "source", "bytes")
    assert_equal Base64.strict_encode64(pdf.bytes), messages.last.dig("content", 2, "document", "source", "bytes")
    assert_equal({ "maxTokens" => 50, "temperature" => 0.2, "topP" => 0.8 }, body.fetch("inferenceConfig"))
    assert_equal({ "any" => {} }, body.dig("toolConfig", "toolChoice"))
    assert_equal true, body.dig("toolConfig", "tools", 0, "toolSpec", "strict")
    assert_includes compiled.path, "inference-profile%2Fa"
  end

  def test_explicit_reasoning_controls_do_not_guess_from_the_model_name
    arguments = { model: "fictional-model", input: "hello", reasoning_enabled: true, reasoning_effort: "high", max_output_tokens: 8192 }
    adaptive = JSON.parse(protocol(bedrock_thinking_control: "adaptive").compile_stream(**arguments).payload)
    assert_equal "adaptive", adaptive.dig("additionalModelRequestFields", "thinking", "type")
    assert_equal "high", adaptive.dig("additionalModelRequestFields", "output_config", "effort")
    budget = JSON.parse(protocol(bedrock_thinking_control: "budget").compile_stream(**arguments).payload)
    assert_equal 7168, budget.dig("additionalModelRequestFields", "thinking", "budget_tokens")
    nested = JSON.parse(protocol(bedrock_thinking_control: "nested_effort", reasoning_effort_map: { "high" => "xhigh" }).compile_stream(**arguments).payload)
    assert_equal "xhigh", nested.dig("additionalModelRequestFields", "reasoning", "effort")
    flat = JSON.parse(protocol(bedrock_thinking_control: "reasoning_effort").compile_stream(**arguments).payload)
    assert_equal "high", flat.dig("additionalModelRequestFields", "reasoning_effort")
    disabled = JSON.parse(protocol(bedrock_thinking_control: "adaptive").compile_stream(**arguments.merge(reasoning_enabled: false)).payload)
    assert_equal({ "thinking" => { "type" => "disabled" } }, disabled.fetch("additionalModelRequestFields"))
    absent = JSON.parse(protocol.compile_stream(**arguments.merge(model: "anthropic.claude-example")).payload)
    refute absent.key?("additionalModelRequestFields")
    bound = JSON.parse(protocol(bedrock_thinking_control: "adaptive", thinking_binding: "drop_block").compile_stream(**arguments).payload)
    assert_equal "drop_block", bound.dig("additionalModelRequestFields", "thinking", "block_binding", "prefix_mismatch_behavior")
    assert_equal ["thinking-binding-controls-2026-08-01"], bound.dig("additionalModelRequestFields", "anthropic_beta")
    gov = JSON.parse(protocol(bedrock_thinking_control: "adaptive", bedrock_omit_thinking_display: true).compile_stream(**arguments).payload)
    refute gov.dig("additionalModelRequestFields", "thinking").key?("display")
    assert_raises(SimpleInference::ValidationError) do
      protocol(bedrock_thinking_control: "adaptive").compile_stream(**arguments.merge(reasoning_effort: "mystery"))
    end
  end

  def test_tool_result_parts_keep_text_image_and_document_bytes
    image = SimpleInference::MediaInput.new(bytes: "image-bytes", media_type: "image/png")
    pdf = SimpleInference::MediaInput.new(bytes: "%PDF-1.7\n", media_type: "application/pdf")
    compiled = protocol.compile_stream(model: "model", input: [
      { role: "user", content: "Read" },
      { type: "function_call", call_id: "read-1", name: "read", arguments: "{}" },
      { type: "function_call_output", call_id: "read-1", output: [
        { type: "text", text: "Captured" },
        { type: "input_image", image_url: image },
        { type: "input_file", file_data: pdf, filename: "capture.pdf" },
      ] },
    ])
    content = JSON.parse(compiled.payload).dig("messages", 2, "content", 0, "toolResult", "content")
    assert_equal "Captured", content.fetch(0).fetch("text")
    assert_equal "image-bytes", Base64.strict_decode64(content.dig(1, "image", "source", "bytes"))
    assert_equal pdf.bytes, Base64.strict_decode64(content.dig(2, "document", "source", "bytes"))
    refute_includes compiled.payload, "SimpleInference::MediaInput"
  end

  def test_client_compiles_the_declared_profile_without_provider_io
    adapter = Adapter.new
    client = SimpleInference::Client.new(base_url: "https://bedrock.example.test", api_key: "secret", adapter: adapter,
      execution_profile: profile_for("bedrock_converse", model_pin: "model-123",
        capabilities: %w[streaming reasoning tool_calls], wire_options: { bedrock_thinking_control: "adaptive" }))
    compiled = client.responses.compile(model: "model-123", input: "Hello", stream: true, reasoning_enabled: true, reasoning_effort: "low")
    assert_equal "/model/model-123/converse-stream", compiled.path
    assert_equal "low", JSON.parse(compiled.payload).dig("additionalModelRequestFields", "output_config", "effort")
    assert_nil adapter.request
  end

  def test_unary_response_and_json_http_error_use_the_shared_contract
    response = { output: { message: { content: [{ text: "answer" }] } }, stopReason: "max_tokens",
                 usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 } }
    adapter = Adapter.new(body: response)
    result = protocol(adapter).create(model: "example", input: "Hello")
    assert_equal "answer", result.output_text
    assert_equal "max_tokens", result.finish_detail
    assert_equal "output_budget_exhausted", SimpleInference::FinishQuality.for(adapter_profile: "bedrock_converse", detail: result.finish_detail)
    assert_equal "https://bedrock.example.test/model/example/converse", adapter.request.fetch(:url)
    denied = Adapter.new(body: { message: "Denied" }, status: 403)
    error = assert_raises(SimpleInference::HTTPError) { protocol(denied).stream(model: "example", input: "Hello").final_result }
    assert_equal 403, error.status
  end

  def test_cut_tool_arguments_remain_unparseable_and_no_terminal_is_an_interruption
    chunks = [
      frame("contentBlockStart", { contentBlockIndex: 0, start: { toolUse: { toolUseId: "call", name: "read" } } }),
      frame("contentBlockDelta", { contentBlockIndex: 0, delta: { toolUse: { input: '{"path":' } } }),
    ]
    error = assert_raises(SimpleInference::ProviderStreamInterruptedError) do
      protocol(Adapter.new(chunks: chunks)).stream(model: "example", input: "Hello").final_result
    end
    assert_equal 2, error.events_seen
    result = protocol(Adapter.new(chunks: chunks + [frame("messageStop", { stopReason: "max_tokens" })])).stream(model: "example", input: "Hello").final_result
    assert_equal '{"path":', result.tool_calls.fetch(0).fetch("arguments")
  end

  def test_corrupt_frames_and_mid_stream_exceptions_cannot_be_normal_results
    bytes = frame("messageStop", { stopReason: "end_turn" })
    bytes.setbyte(bytes.bytesize - 1, bytes.getbyte(bytes.bytesize - 1) ^ 0xff)
    assert_raises(SimpleInference::DecodeError) do
      protocol(Adapter.new(chunks: [bytes])).stream(model: "example", input: "Hello").final_result
    end
    exception = frame("modelStreamErrorException", { message: "failed" }, kind: "exception")
    error = assert_raises(SimpleInference::Error) do
      protocol(Adapter.new(chunks: [frame("messageStop", { stopReason: "end_turn" }), exception])).stream(model: "example", input: "Hello").final_result
    end
    assert_includes error.message, "modelStreamErrorException"
  end

  def test_both_http_adapters_deliver_binary_events_before_the_response_finishes
    [SimpleInference::HTTPAdapters::HTTPX, SimpleInference::HTTPAdapters::AsyncHTTP].each do |adapter_class|
      first = frame("contentBlockDelta", { contentBlockIndex: 0, delta: { text: "first" } })
      last = frame("messageStop", { stopReason: "end_turn" })
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]
      release = Queue.new
      server = Thread.new do
        socket = listener.accept
        headers = []
        while (line = socket.gets) && line != "\r\n"
          headers << line
        end
        length = headers.find { |line| line.downcase.start_with?("content-length:") }.to_s.split(":", 2).last.to_i
        socket.read(length) if length.positive?
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.amazon.eventstream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
        socket.write("#{first.bytesize.to_s(16)}\r\n#{first}\r\n")
        release.pop
        socket.write("#{last.bytesize.to_s(16)}\r\n#{last}\r\n0\r\n\r\n")
      ensure
        socket&.close
      end
      adapter = adapter_class.new
      begin
        wire = SimpleInference::Protocols::BedrockConverse.new(base_url: "http://127.0.0.1:#{port}", adapter: adapter, timeout: 2, read_timeout: 1)
        stream = wire.stream(model: "test", input: "hi")
        events = []
        stream.each do |event|
          events << event.type
          release << true if event.type == "response.output_text.delta"
        end
        assert_equal "first", stream.final_result.output_text, adapter_class.name
        assert_equal ["response.output_text.delta", "response.completed"], events
      ensure
        release << true
        listener.close
        server.join(3)
        adapter.close if adapter_class == SimpleInference::HTTPAdapters::AsyncHTTP
      end
    end
  end

  private

  def protocol(adapter = Adapter.new, **options)
    SimpleInference::Protocols::BedrockConverse.new(base_url: "https://bedrock.example.test", api_key: "secret", adapter: adapter, **options)
  end

  def frame(name, value, kind: "event")
    header = ->(value) { Aws::EventStream::HeaderValue.new(type: "string", value: value) }
    message = Aws::EventStream::Message.new(headers: {
      ":message-type" => header.call(kind),
      (kind == "exception" ? ":exception-type" : ":event-type") => header.call(name),
      ":content-type" => header.call("application/json"),
    }, payload: StringIO.new(JSON.generate(value)))
    Aws::EventStream::Encoder.new.encode(message)
  end
end
