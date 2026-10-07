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
end
