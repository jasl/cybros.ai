require "test_helper"

# Pins per-protocol auth header emission so a rewrite cannot silently change
# which credentials go on the wire (and under which header name).
class TestAuthHeaders < Minitest::Test
  class CapturingJSONAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def initialize(body_json = "{}")
      super()
      @body_json = body_json
    end

    def call(request)
      @last_request = request
      { status: 200, headers: { "content-type" => "application/json" }, body: @body_json }
    end
  end

  class CapturingSSEAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call_stream(request)
      @last_request = request

      sse = +""
      sse << %(data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}\n\n)
      sse << "data: [DONE]\n\n"
      yield sse

      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end

  MINIMAL_CHAT_BODY = %({"id":"chatcmpl_1","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{}})

  def test_openai_responses_create_sends_bearer_authorization
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", api_key: "sk-test", adapter: adapter)

    protocol.create(model: "gpt-4.1-mini", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer sk-test", headers.fetch("Authorization")
  end

  def test_openai_compatible_responses_create_sends_bearer_authorization
    adapter = CapturingJSONAdapter.new(MINIMAL_CHAT_BODY)
    protocol = SimpleInference::Protocols::OpenAICompatibleResponses.new(base_url: "http://example.com", api_key: "sk-test", adapter: adapter)

    protocol.create(model: "gpt-4.1-mini", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer sk-test", headers.fetch("Authorization")
  end

  def test_openai_embeddings_create_sends_bearer_authorization
    adapter = CapturingJSONAdapter.new(%({"data":[],"usage":{}}))
    protocol = SimpleInference::Protocols::OpenAIEmbeddings.new(base_url: "http://example.com", api_key: "sk-test", adapter: adapter)

    protocol.create(model: "text-embedding-3-small", input: ["Hello"])

    headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer sk-test", headers.fetch("Authorization")
  end

  def test_anthropic_messages_create_sends_x_api_key_and_version_without_bearer
    adapter = CapturingJSONAdapter.new(%({"id":"msg_1","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{}}))
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "sk-ant-test", adapter: adapter)

    protocol.create(model: "claude-sonnet-4-6", input: "Hello", max_output_tokens: 4096)

    headers = adapter.last_request.fetch(:headers)
    assert_equal "sk-ant-test", headers.fetch("x-api-key")
    assert_equal "2023-06-01", headers.fetch("anthropic-version")
    refute_includes header_names(adapter), "authorization"
  end

  def test_anthropic_messages_strips_caller_supplied_authorization_header
    adapter = CapturingJSONAdapter.new(%({"content":[]}))
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com",
      api_key: "sk-ant-test",
      headers: { "AUTHORIZATION" => "Bearer stray-token" },
      adapter: adapter,
    )

    protocol.create(model: "claude-sonnet-4-6", input: "Hello", max_output_tokens: 4096)

    refute_includes header_names(adapter), "authorization"
    headers = adapter.last_request.fetch(:headers)
    assert_equal "sk-ant-test", headers.fetch("x-api-key")
  end

  def test_gemini_generate_content_create_sends_x_goog_api_key_without_authorization
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", api_key: "g-test", adapter: adapter)

    protocol.create(model: "gemini-2.5-flash", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "g-test", headers.fetch("x-goog-api-key")
    refute_includes header_names(adapter), "authorization"
    assert_equal "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent", adapter.last_request.fetch(:url)
  end

  def test_gemini_embeddings_create_sends_x_goog_api_key_without_authorization
    adapter = CapturingJSONAdapter.new(%({"embedding":{"values":[0.1]}}))
    protocol = SimpleInference::Protocols::GeminiEmbeddings.new(base_url: "https://generativelanguage.googleapis.com", api_key: "g-test", adapter: adapter)

    protocol.create(model: "gemini-embedding-001", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "g-test", headers.fetch("x-goog-api-key")
    refute_includes header_names(adapter), "authorization"
    assert_equal "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent", adapter.last_request.fetch(:url)
  end

  def test_codex_responses_create_sends_bearer_authorization
    adapter = CapturingSSEAdapter.new
    protocol = SimpleInference::Protocols::CodexResponses.new(base_url: "https://chatgpt.com/backend-api/codex", api_key: "codex-test", adapter: adapter)

    protocol.create(model: "gpt-5-codex", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer codex-test", headers.fetch("Authorization")
  end

  def test_codex_responses_create_passes_through_chatgpt_account_id_header
    adapter = CapturingSSEAdapter.new
    protocol = SimpleInference::Protocols::CodexResponses.new(
      base_url: "https://chatgpt.com/backend-api/codex",
      api_key: "codex-test",
      headers: { "ChatGPT-Account-ID" => "acct_123" },
      adapter: adapter,
    )

    protocol.create(model: "gpt-5-codex", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "acct_123", headers.fetch("ChatGPT-Account-ID")
    assert_equal "Bearer codex-test", headers.fetch("Authorization")
  end

  def test_openai_responses_create_omits_authorization_without_api_key
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", adapter: adapter)

    protocol.create(model: "gpt-4.1-mini", input: "Hello")

    refute_includes header_names(adapter), "authorization"
  end

  def test_openai_embeddings_create_omits_authorization_without_api_key
    adapter = CapturingJSONAdapter.new(%({"data":[],"usage":{}}))
    protocol = SimpleInference::Protocols::OpenAIEmbeddings.new(base_url: "http://example.com", adapter: adapter)

    protocol.create(model: "text-embedding-3-small", input: ["Hello"])

    refute_includes header_names(adapter), "authorization"
  end

  def test_custom_user_agent_header_survives_auth_injection
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::OpenAIResponses.new(
      base_url: "http://example.com",
      api_key: "sk-test",
      headers: { "User-Agent" => "cybros/1.0" },
      adapter: adapter,
    )

    protocol.create(model: "gpt-4.1-mini", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "cybros/1.0", headers.fetch("User-Agent")
    assert_equal "Bearer sk-test", headers.fetch("Authorization")
  end

  def test_caller_supplied_authorization_overrides_injected_bearer
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::OpenAIResponses.new(
      base_url: "http://example.com",
      api_key: "sk-test",
      headers: { "Authorization" => "Bearer override-token" },
      adapter: adapter,
    )

    protocol.create(model: "gpt-4.1-mini", input: "Hello")

    headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer override-token", headers.fetch("Authorization")
  end

  # A missing api_key must mean NO credential header at all — an empty-string
  # x-api-key / x-goog-api-key is provider-visible sloppiness.
  def test_anthropic_messages_omits_x_api_key_without_api_key
    adapter = CapturingJSONAdapter.new(%({"content":[]}))
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", adapter: adapter)

    protocol.create(model: "claude-sonnet-4-6", input: "Hello", max_output_tokens: 4096)

    refute_includes header_names(adapter), "x-api-key"
    assert_equal "2023-06-01", adapter.last_request.fetch(:headers).fetch("anthropic-version")
  end

  def test_gemini_generate_content_omits_x_goog_api_key_without_api_key
    adapter = CapturingJSONAdapter.new
    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "https://generativelanguage.googleapis.com", adapter: adapter)

    protocol.create(model: "gemini-2.5-flash", input: "Hello")

    refute_includes header_names(adapter), "x-goog-api-key"
  end

  def test_gemini_embeddings_omits_x_goog_api_key_without_api_key
    adapter = CapturingJSONAdapter.new(%({"embedding":{"values":[0.1]}}))
    protocol = SimpleInference::Protocols::GeminiEmbeddings.new(base_url: "https://generativelanguage.googleapis.com", adapter: adapter)

    protocol.create(model: "gemini-embedding-001", input: "Hello")

    refute_includes header_names(adapter), "x-goog-api-key"
  end

  private

  def header_names(adapter)
    adapter.last_request.fetch(:headers).keys.map { |name| name.to_s.downcase }
  end
end
