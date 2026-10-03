require "test_helper"
require "minitest/mock"
require "support/platform_http"

class PlatformHttpTest < Minitest::Test
  Response = Data.define(:code, :body)
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

  private

    def post_with(response)
      starter = lambda do |*_arguments, **_options, &block|
        block.call(Connection.new(response))
      end
      Net::HTTP.stub(:start, starter) do
        E2E::PlatformHttp.new("http://example.test").post("/api/v1/example")
      end
    end
end
