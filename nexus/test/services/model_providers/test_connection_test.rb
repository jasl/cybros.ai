require "test_helper"

class ModelProviders::TestConnectionTest < ActiveSupport::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @provider_id = "connection-test"
    @model_ref = "#{@provider_id}/sample"
  end

  test "text tests use the configured endpoint and pin with a small fixed request" do
    configure_model(model: { "model_id" => "upstream-pin", "capabilities" => { "streaming" => false } })
    response = json_response(200, {
      "id" => "test-response", "status" => "completed",
      "output" => [{ "type" => "message", "role" => "assistant",
                     "content" => [{ "type" => "output_text", "text" => "OK" }] }],
    })

    check_with(response) do |result, request|
      assert_predicate result, :success?
      assert_equal :succeeded, result.outcome
      assert_equal 200, result.http_status
      assert_operator result.duration_ms, :>=, 0
      assert_equal "https://provider.invalid/v1/responses", request.fetch(:url)
      body = JSON.parse(request.fetch(:body))
      assert_equal "upstream-pin", body.fetch("model")
      assert_equal 64, body.fetch("max_output_tokens")
      refute body.fetch("stream", false)
      assert_includes request.fetch(:body), "Reply with OK."
      refute body.key?("tools")
      assert_equal 30, request.fetch(:timeout)
    end
  end

  test "stream-only models consume the terminal response and omit unsupported token controls" do
    configure_model(api_format: "codex_responses")

    check_with(sse_success("OK")) do |result, request|
      assert_predicate result, :success?
      body = JSON.parse(request.fetch(:body))
      assert_equal true, body.fetch("stream")
      refute body.key?("max_output_tokens")
      assert_equal 30, request.fetch(:timeout)
      assert_operator request.fetch(:read_timeout), :<, 30
    end
  end

  test "text probes bound output even without optional controls and respect declared limits" do
    [
      [{}, 64],
      [{ "max_output_tokens" => { "minimum" => 128 } }, 128],
      [{ "max_output_tokens" => { "maximum" => 32 } }, 32],
      [{ "max_output_tokens" => { "allowed_values" => [128, 256] } }, 128],
    ].each do |parameters, expected|
      configure_model(model: { "capabilities" => { "generation_parameters" => parameters } })
      check_with(sse_success("OK")) do |result, request|
        assert_predicate result, :success?
        assert_equal expected, JSON.parse(request.fetch(:body)).fetch("max_output_tokens")
      end
    end
  end

  test "embedding image speech and transcription tests send their own workload input" do
    configure_model(api_format: "openai_embeddings")
    check_with(json_response(200, { "data" => [{ "index" => 0, "embedding" => [0.5, 0.25] }] })) do |result, request|
      assert_predicate result, :success?
      assert_equal "https://provider.invalid/v1/embeddings", request.fetch(:url)
      assert_equal "Connection test.", JSON.parse(request.fetch(:body)).fetch("input")
    end

    configure_model(api_format: "openai_images")
    check_with(json_response(200, { "data" => [{ "b64_json" => "cGl4ZWw=" }] })) do |result, request|
      assert_predicate result, :success?
      body = JSON.parse(request.fetch(:body))
      assert_equal "https://provider.invalid/v1/images/generations", request.fetch(:url)
      assert_equal "A plain blue square.", body.fetch("prompt")
      assert_equal 1, body.fetch("n")
    end

    configure_model(api_format: "openai_audio_speech", model: {
      "capabilities" => { "generation_parameters" => {
        "voice" => { "kind" => "string", "default" => "sample-voice", "allowed_values" => ["sample-voice"] },
      } },
    })
    check_with({ status: 200, headers: { "content-type" => "audio/mpeg" }, body: "sample-audio" }) do |result, request|
      assert_predicate result, :success?
      body = JSON.parse(request.fetch(:body))
      assert_equal "https://provider.invalid/v1/audio/speech", request.fetch(:url)
      assert_equal "Connection test.", body.fetch("input")
      assert_equal "sample-voice", body.fetch("voice")
    end

    configure_model(api_format: "openai_audio_transcriptions", model: { "capabilities" => { "input_modalities" => ["audio"] } })
    check_with(json_response(200, { "text" => "" })) do |result, request|
      assert_predicate result, :success?, "silence has a valid empty transcript"
      assert_equal "https://provider.invalid/v1/audio/transcriptions", request.fetch(:url)
      assert_includes request.fetch(:headers).fetch("Content-Type"), "multipart/form-data"
      body = request.fetch(:body).to_s
      assert_includes body, "connection-test.wav"
      assert_includes body, "RIFF"
      assert_includes body, "WAVE"
      assert_includes body, "audio/wav"
    end
  end

  test "custom required inputs are chosen only from declared choices" do
    configure_model(api_format: "openai_audio_speech", model: {
      "capabilities" => { "generation_parameters" => {
        "voice" => { "kind" => "string", "allowed_values" => ["first-voice", "second-voice"] },
      } },
    })
    check_with({ status: 200, headers: {}, body: "sample-audio" }) do |result, request|
      assert_predicate result, :success?
      assert_equal "first-voice", JSON.parse(request.fetch(:body)).fetch("voice")
    end

    configure_model(api_format: "openai_audio_speech", model: {
      "capabilities" => { "generation_parameters" => {} },
    })
    assert_no_provider_io(:test_input_unavailable)

    configure_model(api_format: "openai_audio_transcriptions", model: {
      "capabilities" => { "input_modalities" => ["audio"],
                          "input_media" => { "audio" => { "mime_allowlist" => ["audio/mpeg"] } } },
    })
    assert_no_provider_io(:test_input_unavailable)
  end

  test "missing credentials and disabled providers refuse locally" do
    configure_model(credentials: "api_key")
    assert_no_provider_io(:missing_credential)

    disabled = ModelProviders::DisableLane.call(account: @account, provider_id: @provider_id,
      expected_lock_version: policy.lock_version)
    assert_predicate disabled, :done?
    assert_no_provider_io(:provider_disabled)
  end

  test "an absent or differently scoped model cannot be sent" do
    configure_model
    ["other/sample", "#{@provider_id}/missing"].each do |ref|
      assert_no_provider_io(:not_found, model_ref: ref)
    end
  end

  test "hidden models remain testable without changing their policy or creating work" do
    configure_model
    hidden = ModelProviders::SetModelVisibility.call(account: @account, provider_id: @provider_id,
      model_ref: @model_ref, visible: false, expected_lock_version: policy.lock_version)
    assert_predicate hidden, :done?
    before = policy.attributes

    assert_no_difference ["ModelInvocation.count", "InferenceRequest.count", "UsageRecord.count"] do
      check_with(sse_success("OK")) { |result, _| assert_predicate result, :success? }
    end
    assert_equal before, policy.attributes
  end

  test "only explicit model errors establish absence and never authentication or quota failures" do
    configure_model
    %w[model_not_exist model_retired model_decommissioned].each do |code|
      ["code", "type"].each do |field|
        check_with(json_response(404, { "error" => { field => code, "message" => "private-provider-message" } })) do |result, _|
          assert_equal :model_not_found, result.outcome
          assert_equal 404, result.http_status
          refute_includes result.inspect, "private-provider-message"
        end
      end
    end

    { 401 => :authentication_failed, 403 => :authentication_failed,
      402 => :quota_exceeded, 429 => :rate_limited, 503 => :provider_error }.each do |status, outcome|
      check_with(json_response(status, { "error" => { "code" => "model_not_found" } })) do |result, _|
        assert_equal outcome, result.outcome
      end
    end

    [
      { "error" => { "code" => "model_not_found" } },
      { "error" => { "code" => "model_not_found", "message" => "does not exist or you do not have access" } },
      { "error" => { "code" => "not_found", "message" => "model_not_found" } },
      { "error" => { "type" => "not_found_error" } },
      { "error" => { "status" => "NOT_FOUND" } },
      { "error" => "model_not_found" },
      {},
      [],
      "model_not_exist",
      nil,
    ].each do |body|
      check_with(json_response(404, body)) { |result, _| assert_equal :provider_error, result.outcome }
    end
  end

  test "a structured stream failure can name a missing model without exposing its text" do
    configure_model(api_format: "codex_responses")
    failed = {
      "type" => "response.failed", "response" => {
        "status" => "failed", "error" => { "code" => "model_decommissioned", "message" => "private-stream-error" },
      },
    }
    check_with({ status: 200, headers: { "content-type" => "text/event-stream" },
                 sse: ["data: #{failed.to_json}\n\n"] }) do |result, _|
      assert_equal :model_not_found, result.outcome
      assert_nil result.http_status
      refute_includes result.inspect, "private-stream-error"
    end
  end

  test "transport parse and generic provider failures stay separate from model absence" do
    configure_model
    {
      SimpleInference::TimeoutError.new("private timeout") => :timed_out,
      SimpleInference::ConnectionError.new("private network") => :connection_failed,
      SimpleInference::DecodeError.new("private body") => :invalid_response,
      SimpleInference::ProviderStreamInterruptedError.new("private stream") => :invalid_response,
      SimpleInference::ValidationError.new("private configuration") => :request_invalid,
      SimpleInference::Error.new("private provider") => :provider_error,
    }.each do |error, outcome|
      check_with(error) do |result, _|
        assert_equal outcome, result.outcome
        assert_nil result.http_status
        refute_includes result.inspect, "private"
      end
    end
  end

  test "a content refusal is reported without invalidating the model" do
    configure_model
    check_with(sse_refused("private refusal")) do |result, _|
      assert_equal :request_rejected, result.outcome
      refute_includes result.inspect, "private refusal"
    end
  end

  test "empty successful envelopes do not masquerade as a successful model test" do
    configure_model(model: { "capabilities" => { "streaming" => false } })
    check_with(json_response(200, {})) { |result, _| assert_equal :invalid_response, result.outcome }
    configure_model(api_format: "openai_embeddings")
    check_with(json_response(200, { "data" => [] })) { |result, _| assert_equal :invalid_response, result.outcome }
    configure_model(api_format: "openai_audio_transcriptions", model: { "capabilities" => { "input_modalities" => ["audio"] } })
    check_with(json_response(200, {})) { |result, _| assert_equal :invalid_response, result.outcome }
  end

  private

    def configure_model(api_format: "openai_responses", credentials: "none", model: {})
      saved = ModelProviders::SetDefinition.call(account: @account, provider_id: @provider_id,
        expected_lock_version: policy&.lock_version,
        definition: { "api_format" => api_format, "base_url" => "https://provider.invalid", "credentials" => credentials })
      assert_predicate saved, :done?
      saved = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: @provider_id,
        model_ref: @model_ref, model: model.merge("api_format" => api_format), expected_lock_version: saved.policy.lock_version,
        validate_definition: true)
      assert_predicate saved, :done?
      enabled = ModelProviders::EnableLane.call(account: @account, provider_id: @provider_id,
        expected_lock_version: saved.policy.lock_version)
      assert_predicate enabled, :done?
    end

    def policy
      ModelProviderConfig.find_by(account: @account, provider_id: @provider_id)
    end

    def check_with(response)
      fake = InvocationHarness::FakeAdapter.new(response)
      ModelInvocations::ExecutionAdapter.stub(:for, ->(host) { assert_equal "solid_queue", host; fake }) do
        result = ModelProviders::TestConnection.call(account: @account, provider_id: @provider_id, model_ref: @model_ref)
        assert_equal 1, fake.requests.length, "a test sends exactly once, including on failure"
        yield result, fake.requests.sole
      end
    end

    def assert_no_provider_io(outcome, model_ref: @model_ref)
      ModelCatalog::AssembleClient.stub(:call, ->(**) { flunk "a local refusal cannot send a provider request" }) do
        result = ModelProviders::TestConnection.call(account: @account, provider_id: @provider_id, model_ref: model_ref)
        assert_equal outcome, result.outcome
        assert_nil result.http_status
      end
    end
end
