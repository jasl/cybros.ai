require "json"
require "test_helper"

class TestCompiledRequest < Minitest::Test
  class ExplodingAdapter < SimpleInference::HTTPAdapter
    def call(_env)
      raise "compile must not perform provider IO"
    end

    def call_stream(_env)
      raise "compile must not perform provider IO"
    end
  end

  class CaptureAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests

    def initialize
      @requests = []
    end

    def call(env)
      @requests << env
      {
        status: 200,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(
          "id" => "resp_1",
          "status" => "completed",
          "output" => [
            {
              "type" => "message",
              "role" => "assistant",
              "content" => [{ "type" => "output_text", "text" => "ok" }],
            },
          ],
          "usage" => { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 }
        ),
      }
    end
  end

  class StreamingCaptureAdapter < SimpleInference::HTTPAdapter
    attr_reader :requests

    def initialize
      @requests = []
    end

    def call_stream(env)
      @requests << env
      yield %(data: {"type":"response.output_text.delta","delta":"ok"}\n\n)
      yield %(data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}\n\n)
      yield "data: [DONE]\n\n"

      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end

  class ErrorAdapter < SimpleInference::HTTPAdapter
    def call(_env)
      error_response
    end

    def call_stream(_env)
      error_response
    end

    private

    def error_response
      {
        status: 500,
        headers: { "content-type" => "application/json" },
        body: JSON.generate("error" => { "message" => "boom" }),
      }
    end
  end

  def test_compile_finishes_wire_lowering_without_io_and_execute_only_adds_connection_context
    profile = response_profile
    compile_client = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)

    compiled = compile_client.responses.compile(
      model: profile.model_pin,
      input: "Hello",
      stream: false,
      max_output_tokens: 16
    )

    assert_instance_of SimpleInference::CompiledRequest, compiled
    assert_predicate compiled, :frozen?
    refute compiled.stream?
    refute_respond_to compiled, :to_h

    capture = CaptureAdapter.new
    runtime_client = build_client(profile: profile, adapter: capture, api_key: "runtime-secret")
    result = runtime_client.execute(compiled)

    assert_equal "ok", result.output_text
    request = capture.requests.fetch(0)
    assert_equal compiled.payload, request.fetch(:body)
    assert_equal "Bearer runtime-secret", request.fetch(:headers).fetch("Authorization")
    assert_equal(
      { "model" => profile.model_pin, "input" => "Hello", "max_output_tokens" => 16 },
      JSON.parse(request.fetch(:body))
    )
  end

  def test_compiled_stream_reuses_the_serialized_request_and_assembler
    profile = response_profile
    compiled = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)
               .responses
               .compile(model: profile.model_pin, input: "Hello", stream: true)

    assert compiled.stream?

    capture = StreamingCaptureAdapter.new
    stream = build_client(profile: profile, adapter: capture, api_key: "runtime-secret").execute(compiled)
    result = stream.final_result

    assert_equal "ok", result.output_text
    request = capture.requests.fetch(0)
    assert_equal compiled.payload, request.fetch(:body)
    assert_equal true, JSON.parse(request.fetch(:body)).fetch("stream")
    assert_equal "Bearer runtime-secret", request.fetch(:headers).fetch("Authorization")
  end

  def test_compiled_response_uses_the_runtime_clients_error_policy
    profile = response_profile
    compiled = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)
               .responses
               .compile(model: profile.model_pin, input: "Hello", stream: false)

    result = build_client(
      profile: profile,
      adapter: ErrorAdapter.new,
      api_key: "runtime-secret",
      raise_on_error: false
    ).execute(compiled)

    assert_equal 500, result.provider_response.status

    strict_compiled = build_client(
      profile: profile,
      adapter: ExplodingAdapter.new,
      api_key: nil,
      raise_on_error: false
    ).responses.compile(model: profile.model_pin, input: "Hello", stream: false)

    assert_raises(SimpleInference::HTTPError) do
      build_client(
        profile: profile,
        adapter: ErrorAdapter.new,
        api_key: "runtime-secret",
        raise_on_error: true
      ).execute(strict_compiled)
    end
  end

  def test_compiled_stream_uses_the_runtime_clients_error_policy
    profile = response_profile
    compiled = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)
               .responses
               .compile(model: profile.model_pin, input: "Hello", stream: true)

    result = build_client(
      profile: profile,
      adapter: ErrorAdapter.new,
      api_key: "runtime-secret",
      raise_on_error: false
    ).execute(compiled).final_result

    assert_equal 500, result.provider_response.status

    strict_compiled = build_client(
      profile: profile,
      adapter: ExplodingAdapter.new,
      api_key: nil,
      raise_on_error: false
    ).responses.compile(model: profile.model_pin, input: "Hello", stream: true)

    strict_stream = build_client(
      profile: profile,
      adapter: ErrorAdapter.new,
      api_key: "runtime-secret",
      raise_on_error: true
    ).execute(strict_compiled)
    assert_raises(SimpleInference::HTTPError) { strict_stream.final_result }
  end

  def test_compiled_response_validates_the_runtime_clients_base_url_before_io
    profile = response_profile
    compiled = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)
               .responses
               .compile(model: profile.model_pin, input: "Hello", stream: false)

    runtime_client = build_client(
      profile: profile,
      adapter: ExplodingAdapter.new,
      api_key: "runtime-secret",
      base_url: "not a URL"
    )

    assert_raises(SimpleInference::ConfigurationError) { runtime_client.execute(compiled) }
  end

  def test_compiled_stream_validates_the_runtime_clients_base_url_before_io
    profile = response_profile
    compiled = build_client(profile: profile, adapter: ExplodingAdapter.new, api_key: nil)
               .responses
               .compile(model: profile.model_pin, input: "Hello", stream: true)

    runtime_client = build_client(
      profile: profile,
      adapter: ExplodingAdapter.new,
      api_key: "runtime-secret",
      base_url: "not a URL"
    )

    stream = runtime_client.execute(compiled)
    assert_raises(SimpleInference::ConfigurationError) { stream.final_result }
  end

  private

  def response_profile
    profile_for("openai_responses", provider_id: "openai_api", model_pin: "gpt-6-sol")
  end

  def build_client(profile:, adapter:, api_key:, base_url: "http://example.com", raise_on_error: true)
    SimpleInference::Client.new(
      base_url: base_url,
      api_key: api_key,
      adapter: adapter,
      raise_on_error: raise_on_error,
      execution_profile: profile
    )
  end
end
