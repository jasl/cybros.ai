require "test_helper"

# Source-shaped fixtures, not paid-provider qualification. Pi 6fb2e781,
# packages/ai/src/api/{openai-completions,mistral-conversations,google-generative-ai}.ts.
class TestProviderDialects < Minitest::Test
  def test_static_headers_cannot_override_the_credential_owner
    %w[Authorization X-API-Key x-goog-api-key api-key cf-aig-authorization Cookie].each do |name|
      assert_raises(SimpleInference::ConfigurationError) do
        profile_for("openai_responses", request_headers: { name => "secret" })
      end
    end
    profile = profile_for("openai_responses", request_headers: { "NVCF-POLL-SECONDS" => "3600" })
    assert_equal({ "nvcf-poll-seconds" => "3600" }, profile.request_headers)
  end

  class Capture < SimpleInference::HTTPAdapter
    attr_reader :request

    def initialize(body: {}, events: [])
      super()
      @body, @events = body, events
    end

    def call(request)
      @request = request
      { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(@body) }
    end

    def call_stream(request)
      @request = request
      @events.each { |event| yield "data: #{JSON.generate(event)}\n\n" }
      yield "data: [DONE]\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end

  def test_authentication_scheme_is_independent_of_body_and_late_bound
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://gateway.example", api_key: "compile-key")
    request = protocol.compile_create(model: "m", input: "hi", max_output_tokens: 20)
    refute_includes request.headers.values.join, "compile-key"
    refute_includes request.payload, "compile-key"

    %w[bearer cf-aig-authorization x-api-key].each do |scheme|
      adapter = Capture.new(body: { "content" => [] })
      connection = SimpleInference::Config.new(base_url: "https://gateway.example", api_key: "send-key",
        authentication: scheme, adapter: adapter, headers: { "AUTHORIZATION" => "stray", "x-api-key" => "stray" })
      # Explicit caller headers retain the selected scheme's historical override.
      request.execute(connection)
      names = adapter.request.fetch(:headers).keys.map(&:downcase)
      selected = SimpleInference::Config::AUTHENTICATION_HEADERS.fetch(scheme).first.downcase
      assert_equal [selected], names & SimpleInference::Config::AUTHENTICATION_HEADERS.values.map { |name, _| name.downcase }
      refute_includes connection.inspect, "send-key"
    end
  end

  def test_chat_maximum_role_tools_and_thinking_are_explicit_facts
    profile = profile_for("openai_compatible_chat", model_pin: "m", capabilities: %w[streaming tool_calls], wire_options: {
      chat_path: "/v4/chat/completions", max_tokens_field: "max_completion_tokens",
      supports_developer_role: false, supports_strict_tools: false,
      requires_reasoning_content: true, reasoning_control: "zai", supports_reasoning_effort: false,
      tool_stream: true,
    })
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://chat.example")
    request = client.responses.compile(model: "m", stream: false, input: [
      { role: "developer", content: "instructions" }, { role: "assistant", content: "earlier" },
      { role: "user", content: "hi" },
    ], max_output_tokens: 24, reasoning_enabled: true, reasoning_effort: "high",
      tools: [{ type: "function", name: "read", parameters: { type: "object" }, strict: true }])
    body = JSON.parse(request.payload)
    assert_equal "/v4/chat/completions", request.path
    assert_equal 24, body.fetch("max_completion_tokens")
    refute_includes body, "max_tokens"
    assert_equal "system", body.fetch("messages").first.fetch("role")
    assert_equal "", body.fetch("messages")[1].fetch("reasoning_content")
    refute_includes body.fetch("tools").first.fetch("function"), "strict"
    assert_equal({ "type" => "enabled", "clear_thinking" => false }, body.fetch("thinking"))
    assert_equal true, body.fetch("tool_stream")
    refute_includes body, "reasoning_effort"
  end

  def test_azure_responses_preserves_the_pinned_sdk_query_and_api_key_header
    adapter = Capture.new(body: { "id" => "r", "status" => "completed", "output" => [] })
    profile = profile_for("openai_responses", model_pin: "deployment", authentication: "api-key",
      wire_options: { responses_path: "/openai/v1/responses?api-version=v1" })
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://resource.openai.azure.com",
      api_key: "azure-key", authentication: profile.authentication, adapter: adapter)
    request = client.responses.compile(model: "deployment", input: "hi", stream: false)
    client.execute(request)
    assert_equal "https://resource.openai.azure.com/openai/v1/responses?api-version=v1", adapter.request.fetch(:url)
    assert_equal "azure-key", adapter.request.fetch(:headers).fetch("api-key")
    refute adapter.request.fetch(:headers).keys.any? { |name| name.downcase == "authorization" }
    assert_equal "deployment", JSON.parse(adapter.request.fetch(:body)).fetch("model")
  end

  def test_azure_chat_uses_the_same_resource_origin_as_responses
    adapter = Capture.new(body: { "choices" => [] })
    profile = profile_for("openai_compatible_chat", model_pin: "deployment",
      wire_options: { chat_path: "/openai/v1/chat/completions" })
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://resource.openai.azure.com",
      api_key: "azure-key", authentication: "api-key", adapter: adapter)
    client.execute(client.responses.compile(model: "deployment", input: "hi", stream: false))
    assert_equal "https://resource.openai.azure.com/openai/v1/chat/completions", adapter.request.fetch(:url)
    assert_equal "azure-key", adapter.request.fetch(:headers).fetch("api-key")
  end

  def test_mistral_thinking_parts_stay_out_of_answer_and_replay_as_parts
    adapter = Capture.new(events: [
      { "choices" => [{ "delta" => { "content" => [
        { "type" => "thinking", "thinking" => [{ "type" => "text", "text" => "consider" }] },
        { "type" => "text", "text" => "answer" },
      ] }, "finish_reason" => nil }] },
      { "choices" => [{ "delta" => {}, "finish_reason" => "stop" }], "usage" => { "prompt_tokens" => 2, "completion_tokens" => 3 } },
    ])
    client = SimpleInference::Client.new(execution_profile: profile_for("mistral_chat", model_pin: "m"),
      base_url: "https://mistral.example", adapter: adapter)
    stream = client.responses.stream(model: "m", input: "hi")
    events = stream.to_a
    result = stream.final_result
    assert_equal "answer", result.output_text
    assert_equal "consider", result.assistant_message.fetch("reasoning_content")
    assert events.any? { |event| event.respond_to?(:delta) && event.delta == "consider" }
    request = client.responses.compile(model: "m", stream: false,
      input: [result.assistant_message, { role: "user", content: "next" }])
    assistant = JSON.parse(request.payload).fetch("messages").first
    assert_equal false, assistant.fetch("prefix")
    assert_equal "thinking", assistant.fetch("content").first.fetch("type")
    refute_includes assistant, "reasoning_content"
  end

  def test_gemini_budget_and_vertex_model_path_are_explicit
    profile = profile_for("gemini_generate_content", model_pin: "gemini-2.5-pro", wire_options: {
      models_path: "/v1/publishers/google/models", gemini_thinking_control: "budget",
      thinking_budgets: { "low" => 2048, "high" => 32768 },
    })
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "https://aiplatform.example")
    request = client.responses.compile(model: "gemini-2.5-pro", input: "hi", stream: false,
      reasoning_enabled: true, reasoning_effort: "high")
    assert_equal "/v1/publishers/google/models/gemini-2.5-pro:generateContent", request.path
    assert_equal({ "includeThoughts" => true, "thinkingBudget" => 32768 },
      JSON.parse(request.payload).dig("generationConfig", "thinkingConfig"))
    request = client.responses.compile(model: "gemini-2.5-pro", input: "hi", stream: false, reasoning_enabled: false)
    assert_equal({ "thinkingBudget" => 0 }, JSON.parse(request.payload).dig("generationConfig", "thinkingConfig"))
  end

  def test_mistral_tool_ids_remain_paired_and_distinct_after_cross_provider_replay
    client = SimpleInference::Client.new(execution_profile: profile_for("mistral_chat", model_pin: "m"),
      base_url: "https://mistral.example")
    calls = ["abc123XYZ", "abc_123XYZ", "call-long-id-from-another-provider"]
    input = [{ role: "assistant", content: nil, tool_calls: calls.map do |id|
      { id: id, type: "function", function: { name: "read", arguments: "{}" } }
    end }] + calls.map { |id| { role: "tool", tool_call_id: id, content: "done" } }
    request = client.responses.compile(model: "m", stream: false, input: input)
    messages = JSON.parse(request.payload).fetch("messages")
    normalized = messages.first.fetch("tool_calls").map { |call| call.fetch("id") }
    assert_equal "abc123XYZ", normalized.first
    assert_equal 3, normalized.uniq.length
    normalized.each { |id| assert_match(/\A[a-zA-Z0-9]{9}\z/, id) }
    assert_equal normalized, messages.drop(1).map { |message| message.fetch("tool_call_id") }
    assert_equal calls, input.first.fetch(:tool_calls).map { |call| call.fetch(:id) }
  end
end
