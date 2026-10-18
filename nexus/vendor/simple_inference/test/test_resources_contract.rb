require "json"
require "test_helper"

# The caller-facing resource boundary over audited execution profiles.
#
# Protocol selection is the registry's explicit closed map — these tests prove
# there is no substring routing and no silent fall-through left: an adapter
# profile without a conforming protocol class fails closed, and every
# capability/modality/workload/model-pin gate reads an explicit profile fact.
class TestResourcesContract < Minitest::Test
  include TestProfiles

  class CaptureAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests

    def initialize(body:, content_type: "application/json")
      @requests = []
      @body = body
      @content_type = content_type
    end

    def call(env)
      @requests << env
      { status: 200, headers: { "content-type" => @content_type }, body: @body }
    end
  end

  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_env)
      raise "no request may be emitted for a rejected preparation"
    end

    def call_stream(_env)
      raise "no request may be emitted for a rejected preparation"
    end
  end

  RESPONSES_BODY = JSON.generate(
    "id" => "resp_123",
    "output" => [
      { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Hello from responses" }] },
    ],
    "usage" => { "input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7 }
  )

  ANTHROPIC_BODY = JSON.generate(
    "id" => "msg_123",
    "content" => [{ "type" => "text", "text" => "Hello from messages" }],
    "stop_reason" => "end_turn",
    "usage" => { "input_tokens" => 3, "output_tokens" => 4 }
  )

  GEMINI_BODY = JSON.generate(
    "candidates" => [
      { "content" => { "parts" => [{ "text" => "Hello from gemini" }] }, "finishReason" => "STOP" },
    ],
    "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 4, "totalTokenCount" => 7 }
  )

  # Composed, not looked up: the wire's defaults plus an identity, which is
  # the whole of what a lane is now.
  def lane_profile(format, provider_id:, model_pin: "test-model")
    profile_for(format, provider_id: provider_id, model_pin: model_pin)
  end

  def build_client(profile:, adapter:, base_url: "http://example.com", **options)
    SimpleInference::Client.new(
      base_url: base_url,
      api_key: "secret",
      adapter: adapter,
      execution_profile: profile,
      **options
    )
  end

  # --- explicit routing through the registry's closed protocol map ---

  def test_openai_profile_routes_to_the_responses_protocol
    adapter = CaptureAdapter.new(body: RESPONSES_BODY)
    client = build_client(
      profile: lane_profile("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol"),
      adapter: adapter
    )

    result = client.responses.create(model: "gpt-6-sol", input: "Hello")

    assert_instance_of SimpleInference::Responses::Result, result
    assert_equal "Hello from responses", result.output_text
    request = adapter.requests.fetch(0)
    assert_equal "http://example.com/v1/responses", request.fetch(:url)
    assert_equal "gpt-6-sol", JSON.parse(request.fetch(:body)).fetch("model")
  end

  def test_codex_profile_routes_to_the_codex_responses_protocol
    adapter = CaptureAdapter.new(body: RESPONSES_BODY)
    client = build_client(
      profile: lane_profile("codex_responses", provider_id: "codex_subscription", model_pin: "gpt-6-sol"),
      adapter: adapter
    )

    client.responses.create(model: "gpt-6-sol", input: "Hello")

    request = adapter.requests.fetch(0)
    # The codex profile pins the backend-root responses path ("/responses" on
    # the chatgpt backend base URL), not the public-API "/v1/responses".
    assert_equal "http://example.com/responses", request.fetch(:url)
    assert_equal "gpt-6-sol", JSON.parse(request.fetch(:body)).fetch("model")
  end

  def test_anthropic_profile_routes_to_the_messages_protocol
    adapter = CaptureAdapter.new(body: ANTHROPIC_BODY)
    client = build_client(
      profile: lane_profile("anthropic_messages", provider_id: "anthropic", model_pin: "claude-opus-5-5"),
      adapter: adapter
    )

    result = client.responses.create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)

    assert_equal "Hello from messages", result.output_text
    request = adapter.requests.fetch(0)
    assert_includes request.fetch(:url), "/messages"
  end

  def test_gemini_profile_routes_to_the_generate_content_protocol
    adapter = CaptureAdapter.new(body: GEMINI_BODY)
    client = build_client(
      profile: lane_profile("gemini_generate_content", provider_id: "gemini", model_pin: "gemini-3.7-flash"),
      adapter: adapter
    )

    result = client.responses.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "Hello from gemini", result.output_text
    request = adapter.requests.fetch(0)
    assert_includes request.fetch(:url), "generateContent"
  end

  # --- fail-closed profile gates: no request is emitted on rejection ---

  def test_responses_requires_a_text_generation_profile
    client = build_client(
      profile: lane_profile("openai_images", provider_id: "openai_api", model_pin: "gpt-image-2-2026-04-21"),
      adapter: ExplodingAdapter.new
    )

    error = assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(model: "gpt-image-2-2026-04-21", input: "Hello")
    end

    assert_includes error.message, "text_generation"
  end

  def test_responses_rejects_a_model_off_the_profile_pin
    client = build_client(
      profile: lane_profile("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol"),
      adapter: ExplodingAdapter.new
    )

    error = assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(model: "gpt-5.6", input: "Hello")
    end

    assert_includes error.message, "pinned model"
  end

  def test_streaming_requires_the_streaming_capability
    profile = build_execution_profile(capabilities: %w[tool_calls])
    client = build_client(profile: profile, adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::CapabilityError) do
      client.responses.stream(model: "gpt-6-sol", input: "Hello")
    end
  end

  def test_function_tools_require_the_tool_calls_capability
    profile = build_execution_profile(capabilities: %w[streaming])
    client = build_client(profile: profile, adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(
        model: "gpt-6-sol",
        input: "Hello",
        tools: [{ type: "function", name: "lookup" }]
      )
    end
  end

  def test_builtin_tools_require_the_provider_builtin_tools_capability
    profile = build_execution_profile(capabilities: %w[streaming tool_calls])
    client = build_client(profile: profile, adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(model: "gpt-6-sol", input: "Hello", tools: [{ type: "web_search" }])
    end
  end

  def test_builtin_tools_can_be_disabled_per_request
    client = build_client(
      profile: lane_profile("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol"),
      adapter: ExplodingAdapter.new
    )

    error = assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(
        model: "gpt-6-sol",
        input: "Hello",
        tools: [{ type: "web_search" }],
        allow_builtin_tools: false
      )
    end

    assert_includes error.message, "disabled for this request"
  end

  def test_conversation_state_requires_the_capability
    profile = build_execution_profile(capabilities: %w[streaming])
    client = build_client(profile: profile, adapter: ExplodingAdapter.new)

    assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(model: "gpt-6-sol", input: "Hello", previous_response_id: "resp_1")
    end
  end

  def test_image_input_requires_the_image_modality
    profile = build_execution_profile(input_modalities: [])
    client = build_client(profile: profile, adapter: ExplodingAdapter.new)

    error = assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(
        model: "gpt-6-sol",
        input: [{ type: "input_image", image_url: "data:image/png;base64,AAAA" }]
      )
    end

    assert_includes error.message, "image inputs are not enabled"
  end

  def test_inline_data_file_parts_classify_without_activesupport_and_fail_closed
    client = build_client(
      profile: build_execution_profile(input_modalities: ["image"]),
      adapter: ExplodingAdapter.new
    )

    error = assert_raises(SimpleInference::CapabilityError) do
      client.responses.create(
        model: "gpt-6-sol",
        input: [{ inline_data: { mime_type: "application/pdf", data: "AAAA" } }]
      )
    end

    assert_includes error.message, "file inputs are not enabled"
  end

  # --- SDK-only control flags never reach the wire ---

  def test_create_strips_control_flags_from_the_wire_body
    adapter = CaptureAdapter.new(body: RESPONSES_BODY)
    client = build_client(
      profile: lane_profile("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol"),
      adapter: adapter
    )

    client.responses.create(
      model: "gpt-6-sol",
      input: "Hello",
      allow_builtin_tools: true,
      prefer_stateful_responses: true,
      allow_multimodal_inputs: true
    )

    body = JSON.parse(adapter.requests.fetch(0).fetch(:body))
    SimpleInference::Planning::RequestValidator::RESPONSES_CONTROL_KEYS.each do |key|
      refute body.key?(key.to_s), "control flag #{key} leaked to the wire"
    end
  end

  # --- non-text workload boundaries through registered profiles ---

  def test_images_generate_routes_and_strips_the_local_allow_flag
    adapter = CaptureAdapter.new(body: JSON.generate("data" => [{ "b64_json" => "AAAA" }]))
    client = build_client(
      profile: lane_profile("openai_images", provider_id: "openai_api", model_pin: "gpt-image-2-2026-04-21"),
      adapter: adapter
    )

    result = client.images.generate(
      model: "gpt-image-2-2026-04-21",
      prompt: "a tiny house",
      allow_image_generation: true
    )

    assert_instance_of SimpleInference::Images::Result, result
    request = adapter.requests.fetch(0)
    assert_equal "http://example.com/v1/images/generations", request.fetch(:url)
    refute JSON.parse(request.fetch(:body)).key?("allow_image_generation")
  end

  def test_images_generate_rejects_when_request_disables_image_generation
    client = build_client(
      profile: lane_profile("openai_images", provider_id: "openai_api", model_pin: "gpt-image-2-2026-04-21"),
      adapter: ExplodingAdapter.new
    )

    assert_raises(SimpleInference::CapabilityError) do
      client.images.generate(model: "gpt-image-2-2026-04-21", prompt: "x", allow_image_generation: false)
    end
  end

  def test_audio_speech_routes_through_the_speech_profile
    adapter = CaptureAdapter.new(body: "BYTES", content_type: "audio/mpeg")
    client = build_client(
      profile: lane_profile("openai_audio_speech", provider_id: "openai_api", model_pin: "gpt-4o-mini-tts-2025-12-15"),
      adapter: adapter
    )

    result = client.audio.speech.create(model: "gpt-4o-mini-tts-2025-12-15", input: "Hello", voice: "alloy")

    assert_instance_of SimpleInference::Audio::SpeechResult, result
    assert_equal "http://example.com/v1/audio/speech", adapter.requests.fetch(0).fetch(:url)
  end

  def test_audio_transcriptions_route_and_sanitize_multipart_header_values
    adapter = CaptureAdapter.new(body: JSON.generate("text" => "hi"))
    client = build_client(
      profile: lane_profile("openai_audio_transcriptions", provider_id: "openai_api", model_pin: "gpt-4o-mini-transcribe-2025-12-15"),
      adapter: adapter
    )

    # A header-injection content type can no longer reach the serializer at
    # all: the DETECTED closed-vocabulary MIME goes on the wire (byte truth).
    # Filename sanitization remains the serializer's job.
    client.audio.transcriptions.create(
      model: "gpt-4o-mini-transcribe-2025-12-15",
      file: {
        filename: "sample\"\r\nX-Bad: 1.wav",
        body: "RIFF\x24\x00\x00\x00WAVEfmt ".b,
      }
    )

    request = adapter.requests.fetch(0)
    assert_equal "http://example.com/v1/audio/transcriptions", request.fetch(:url)
    assert_includes request.dig(:headers, "Content-Type"), "multipart/form-data"
    request_body = request.fetch(:body).to_s
    refute_includes request_body, "\r\nX-Bad:"
    assert_includes request_body, %(filename="sample\\"  X-Bad: 1.wav")
    assert_includes request_body, "Content-Type: audio/wav\r\n\r\n"
  end

  def test_audio_transcriptions_reject_filesystem_path_file_parts
    client = build_client(
      profile: lane_profile("openai_audio_transcriptions", provider_id: "openai_api", model_pin: "gpt-4o-mini-transcribe-2025-12-15"),
      adapter: ExplodingAdapter.new
    )

    error = assert_raises(SimpleInference::ValidationError) do
      client.audio.transcriptions.create(
        model: "gpt-4o-mini-transcribe-2025-12-15",
        file: { path: "/tmp/sample.wav" }
      )
    end

    assert_includes error.message, "paths are not accepted"
  end

  def test_audio_transcriptions_reject_string_keyed_file_hashes
    client = build_client(
      profile: lane_profile("openai_audio_transcriptions", provider_id: "openai_api", model_pin: "gpt-4o-mini-transcribe-2025-12-15"),
      adapter: ExplodingAdapter.new
    )

    assert_raises(SimpleInference::ValidationError) do
      client.audio.transcriptions.create(
        model: "gpt-4o-mini-transcribe-2025-12-15",
        file: { "filename" => "sample.wav", "body" => "RIFF....WAVE" }
      )
    end
  end

  def test_embeddings_route_through_the_embedding_profile
    adapter = CaptureAdapter.new(
      body: JSON.generate("data" => [{ "index" => 0, "embedding" => [0.1, 0.2] }])
    )
    client = build_client(
      profile: lane_profile("openai_embeddings", provider_id: "openai_api", model_pin: "text-embedding-3-large"),
      adapter: adapter
    )

    result = client.embeddings.create(model: "text-embedding-3-large", input: "Hello")

    assert_instance_of SimpleInference::Embeddings::Result, result
    request = adapter.requests.fetch(0)
    body = JSON.parse(request.fetch(:body))
    assert_equal "http://example.com/v1/embeddings", request.fetch(:url)
    assert_equal "text-embedding-3-large", body.fetch("model")
    assert_equal "Hello", body.fetch("input")
  end

  # --- connection/path composition survives the registry rewiring ---

  def test_base_url_api_prefix_is_preserved_for_short_responses_paths
    adapter = CaptureAdapter.new(body: RESPONSES_BODY)
    profile = build_execution_profile(wire_options: { responses_path: "/responses" })
    client = build_client(profile: profile, adapter: adapter, base_url: "http://example.com/v1")

    client.responses.create(model: "gpt-6-sol", input: "Hello")

    assert_equal "http://example.com/v1/responses", adapter.requests.fetch(0).fetch(:url)
  end

  # --- result value discipline ---

  def test_responses_result_keeps_normalized_parser_values
    output_items = []
    tool_calls = []
    assistant_message = {}
    provider_tool_call = { "type" => "function_call", "call_id" => "c1", "name" => "f", "arguments" => "{}" }
    output_items << provider_tool_call
    tool_calls << provider_tool_call
    result = SimpleInference::Responses::Result.new(
      output_text: "hi",
      output_items: output_items,
      tool_calls: tool_calls,
      assistant_message: assistant_message,
      usage: { "total_tokens" => 1 },
      finish_reason: "stop",
      finish_detail: nil,
      provider_response: nil,
      provider_format: "responses",
    )

    assert result.frozen?, "the value object itself is frozen"
    assert_same output_items, result.output_items
    assert_same tool_calls, result.tool_calls
    assert_same assistant_message, result.assistant_message
  end
end
