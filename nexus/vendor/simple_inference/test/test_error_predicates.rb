require "test_helper"

# The one question a caller asks of a provider failure without probing its
# class: did the provider say it is overloaded right now? 503 and Anthropic's
# 529 on the HTTP answer, and the streamed `overloaded_error` event that
# Anthropic documents as the stream's 529. A rate limit (429) is the
# account's quota, not the provider's load, and every other error answers no.
class TestErrorPredicates < Minitest::Test
  Response = Data.define(:status, :headers, :body, :raw_body)

  def http_error(status)
    SimpleInference::HTTPError.new(
      "HTTP #{status}", response: Response.new(status: status, headers: {}, body: nil, raw_body: "")
    )
  end

  def test_an_overloaded_http_status_answers_overloaded
    assert_predicate http_error(503), :overloaded?
    assert_predicate http_error(529), :overloaded?
  end

  def test_other_http_statuses_are_not_overload
    [400, 408, 429, 500, 502, 504].each do |status|
      refute_predicate http_error(status), :overloaded?, "HTTP #{status}"
    end
  end

  def test_the_streamed_overload_event_is_overload
    error = SimpleInference::Protocols::AnthropicMessages::StreamOverloadedError.new("overloaded_error")

    assert_predicate error, :overloaded?
  end

  def test_every_other_error_is_not_overload
    [
      SimpleInference::Error.new("x"),
      SimpleInference::TimeoutError.new("x"),
      SimpleInference::ConnectionError.new("x"),
      SimpleInference::ProviderStreamInterruptedError.new("x"),
      SimpleInference::ValidationError.new("x"),
    ].each do |error|
      refute_predicate error, :overloaded?, error.class.name
    end
  end
  def test_transient_http_and_transport_errors
    [429, 500, 502, 503, 504, 529].each { |status| assert_predicate http_error(status), :transient? }
    [400, 401, 403, 404, 408, 413, 422].each { |status| refute_predicate http_error(status), :transient? }
    [SimpleInference::TimeoutError, SimpleInference::ConnectionError,
      SimpleInference::ProviderStreamInterruptedError].each do |kind|
      assert_predicate kind.new("broken"), :transient?
    end
    refute_predicate SimpleInference::Error.new("server error"), :transient?
  end

  def test_only_typed_server_stream_failures_are_transient
    response = SimpleInference::Protocols::OpenAIResponses::ResponseFailedError
    assert_predicate response.new("failed", code: "server_error"), :transient?
    %w[invalid_prompt context_length_exceeded unknown].each do |code|
      refute_predicate response.new("server error", code: code), :transient?
    end
    stream = SimpleInference::Protocols::OpenAIResponses::StreamErrorEventError
    assert_predicate stream.new("failed", payload: { "code" => "server_error" }), :transient?
    refute_predicate stream.new("failed", payload: { "code" => "invalid_request_error" }), :transient?
    assert_predicate SimpleInference::Protocols::AnthropicMessages::StreamServerError.new("api_error"), :transient?
  end
end
