require "json"
require "test_helper"

# Pins Config URL/prefix/api-key/header/timeout behaviors end-to-end through
# protocol requests (captured adapter env), as a pre-rewrite safety net.
class TestConfigBehaviors < Minitest::Test
  def test_base_url_ending_in_v1_does_not_double_the_default_api_prefix
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com/v1",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_equal "http://example.com/v1/embeddings", adapter.last_request.fetch(:url)
    assert_equal "http://example.com", protocol.config.base_url
    assert_equal "/v1", protocol.config.api_prefix
    assert protocol.config.base_url_included_api_prefix?
  end

  def test_base_url_with_trailing_slash_after_v1_is_normalized_the_same_way
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com/v1/",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_equal "http://example.com/v1/embeddings", adapter.last_request.fetch(:url)
    assert_equal "http://example.com", protocol.config.base_url
    assert protocol.config.base_url_included_api_prefix?
  end

  def test_base_url_without_api_prefix_is_kept_and_reports_prefix_not_included
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_equal "http://example.com/v1/embeddings", adapter.last_request.fetch(:url)
    assert_equal "http://example.com", protocol.config.base_url
    refute protocol.config.base_url_included_api_prefix?
  end

  def test_v1_footgun_applies_to_chat_completions_urls_too
    adapter = build_capture_adapter(body: JSON.generate({ "choices" => [] }))
    protocol =
      SimpleInference::Protocols::OpenAICompatible.new(
        base_url: "http://example.com/v1",
        adapter: adapter,
      )

    protocol.chat_completions(model: "m", messages: [{ role: "user", content: "hi" }])

    assert_equal "http://example.com/v1/chat/completions", adapter.last_request.fetch(:url)
  end

  def test_explicit_base_url_included_api_prefix_true_is_respected
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        base_url_included_api_prefix: true,
        embeddings_path: "/embeddings",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert protocol.config.base_url_included_api_prefix?
    # With the flag on, a short custom path gets the api_prefix re-added.
    assert_equal "http://example.com/v1/embeddings", adapter.last_request.fetch(:url)
  end

  def test_empty_string_api_key_is_treated_as_missing_and_sends_no_authorization_header
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        api_key: "",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_nil protocol.config.api_key
    request_headers = adapter.last_request.fetch(:headers)
    refute_includes request_headers.keys, "Authorization"
  end

  def test_present_api_key_sends_bearer_authorization_header
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        api_key: "secret",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    request_headers = adapter.last_request.fetch(:headers)
    assert_equal "Bearer secret", request_headers.fetch("Authorization")
  end

  def test_custom_api_prefix_lands_in_request_urls
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        api_prefix: "/api/v2",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_equal "http://example.com/api/v2/embeddings", adapter.last_request.fetch(:url)
  end

  def test_custom_api_prefix_footgun_is_also_deduplicated
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com/api/v2",
        api_prefix: "/api/v2",
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    assert_equal "http://example.com/api/v2/embeddings", adapter.last_request.fetch(:url)
    assert protocol.config.base_url_included_api_prefix?
  end

  def test_extra_string_keyed_headers_are_merged_into_requests
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        headers: { "X-Custom" => "1" },
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    request_headers = adapter.last_request.fetch(:headers)
    assert_equal "1", request_headers.fetch("X-Custom")
    assert_equal "application/json", request_headers.fetch("Accept")
  end

  def test_timeouts_flow_into_the_adapter_request_env
    adapter = build_capture_adapter
    protocol =
      SimpleInference::Protocols::OpenAIEmbeddings.new(
        base_url: "http://example.com",
        timeout: 12.5,
        open_timeout: 3,
        read_timeout: 9,
        adapter: adapter,
      )

    protocol.create(model: "m", input: "hello")

    request_env = adapter.last_request
    assert_in_delta 12.5, request_env.fetch(:timeout)
    assert_in_delta 3.0, request_env.fetch(:open_timeout)
    assert_in_delta 9.0, request_env.fetch(:read_timeout)
  end

  # --- the fully-explicit Config contract (no ENV, no default endpoint,
  # unknown keys rejected, config: pass-through) ---

  def test_base_url_is_required
    assert_raises(ArgumentError) { SimpleInference::Config.new }

    error = assert_raises(SimpleInference::ConfigurationError) { SimpleInference::Config.new(base_url: " ") }

    assert_includes error.message, "base_url is required"
  end

  # Unknown keywords are Ruby's own ArgumentError — no hand-rolled allowlist.
  def test_config_rejects_unknown_options
    error =
      assert_raises(ArgumentError) do
        SimpleInference::Config.new(base_url: "http://example.com", api_keyy: "typo")
      end

    assert_includes error.message, "api_keyy"
  end

  def test_client_rejects_unknown_options
    error =
      assert_raises(ArgumentError) do
        SimpleInference::Client.new(
          base_url: "http://example.com", execution_profile: profile_for("openai_responses"), provider_profil: {}
        )
      end

    assert_includes error.message, "provider_profil"
  end

  def test_protocol_rejects_unknown_construction_options
    error =
      assert_raises(ArgumentError) do
        SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", responses_pathz: "/x")
      end

    assert_includes error.message, "responses_pathz"
  end

  def test_protocols_share_the_client_config_by_reference
    adapter = build_capture_adapter(body: JSON.generate({ "id" => "r", "output" => [] }))
    profile = profile_for("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol")
    client = SimpleInference::Client.new(
      base_url: "http://example.com",
      api_key: "secret",
      adapter: adapter,
      execution_profile: profile,
    )

    protocol = SimpleInference::ApiFormat.protocol_for(profile: profile, config: client.config)

    assert_same client.config, protocol.config, "the registry passes the parsed Config by reference — no re-parse"
  end

  def test_config_pass_through_cannot_be_combined_with_connection_options
    config = SimpleInference::Config.new(base_url: "http://example.com")

    error =
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Protocols::OpenAIResponses.new(config: config, api_key: "other")
      end

    assert_includes error.message, "cannot be combined"
  end

  def test_config_defaults_the_adapter_and_validates_its_type
    config = SimpleInference::Config.new(base_url: "http://example.com")

    assert_instance_of SimpleInference::HTTPAdapters::Default, config.adapter

    error =
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Config.new(base_url: "http://example.com", adapter: "not an adapter")
      end
    assert_includes error.message, "adapter"
  end

  private

  def build_capture_adapter(body: nil)
    response_body =
      body || JSON.generate(
        {
          "data" => [{ "index" => 0, "embedding" => [0.1, 0.2] }],
          "usage" => { "prompt_tokens" => 1, "total_tokens" => 1 },
        }
      )

    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      define_method(:call) do |env|
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: response_body,
        }
      end
    end.new
  end
end
