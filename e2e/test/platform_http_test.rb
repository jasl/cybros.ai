require "test_helper"
require "minitest/mock"
require "support/platform_http"

class PlatformHttpTest < Minitest::Test
  Response = Data.define(:code, :body) do
    def [](_header) = "0"
  end
  Connection = Data.define(:response) do
    def request(_request)
      response
    end
  end

  def test_returns_non_json_server_error_by_status
    result = post_with(Response.new(code: "502", body: "Bad Gateway"))

    assert_equal 502, result.status
    assert_equal "Bad Gateway", result.body
  end

  def test_returns_empty_server_error_by_status
    result = post_with(Response.new(code: "503", body: ""))

    assert_equal 503, result.status
    assert_nil result.body
  end

  def test_accepts_an_empty_no_content_success
    result = post_with(Response.new(code: "204", body: ""))

    assert_equal 204, result.status
    assert_nil result.body
  end

  def test_rejects_non_json_defined_response
    error = assert_raises(RuntimeError) do
      post_with(Response.new(code: "422", body: "not JSON"))
    end

    assert_match(/Platform response was not JSON \(status 422\)/, error.message)
  end

  def test_rejects_empty_defined_response
    error = assert_raises(RuntimeError) do
      post_with(Response.new(code: "422", body: ""))
    end

    assert_match(/Platform response was not JSON \(status 422\)/, error.message)
  end

  def test_rate_limit_is_returned_without_retry_by_default
    result = post_with(Response.new(code: "429", body: '{"error":{"code":"rate_limited"}}'))

    assert_equal 429, result.status
    assert_equal "rate_limited", result.body.fetch("error").fetch("code")
  end

  def test_opted_in_preparation_retries_rate_limit_and_preserves_created_status
    responses = [
      Response.new(code: "429", body: '{"error":{"code":"rate_limited"}}'),
      Response.new(code: "201", body: '{"secret":"synthetic-key"}'),
    ]
    capture_io do
      result = post_responses(responses, retry_rate_limit: true)

      assert_equal 201, result.status
      assert_equal "synthetic-key", result.body.fetch("secret")
    end
    assert_empty responses
  end

  def test_opted_in_preparation_does_not_retry_server_errors
    result = post_responses([Response.new(code: "502", body: "Bad Gateway")], retry_rate_limit: true)

    assert_equal 502, result.status
    assert_equal "Bad Gateway", result.body
  end

  private

    def post_with(response)
      responses = [response]
      result = post_responses(responses)
      assert_empty responses
      result
    end

    def post_responses(responses, **options)
      starter = lambda do |*_arguments, **_options, &block|
        block.call(Connection.new(responses.shift || raise("Unexpected retry")))
      end
      Net::HTTP.stub(:start, starter) do
        E2E::PlatformHttp.new("http://example.test").post("/api/v1/example", **options)
      end
    end
end
