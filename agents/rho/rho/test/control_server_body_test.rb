require "test_helper"

class ControlServerBodyTest < Minitest::Test
  Request = Data.define(:body, :headers)

  def test_a_json_post_releases_the_persistent_connection_for_the_next_request
    control = Rho::ControlServer.new(bind: "127.0.0.1", port: 0, routes: {
      ["POST", "/session"] => ->(request) { [200, Rho::ControlServer.json_body(request)] },
      ["GET", "/status"] => ->(_request) { [200, { status: "ok" }] },
    }).run

    Net::HTTP.start("127.0.0.1", control.port, read_timeout: 2, max_retries: 0) do |http|
      post = Net::HTTP::Post.new("/session", "Content-Type" => "application/json")
      post.body = JSON.generate(code: "synthetic-console-code")
      assert_equal "200", http.request(post).code
      response = http.request(Net::HTTP::Get.new("/status"))
      assert_equal "200", response.code
      assert_equal({ "status" => "ok" }, JSON.parse(response.body))
    end
  ensure
    control&.stop
  end

  def test_json_can_span_body_chunks
    body = Protocol::HTTP::Body::Buffered.new(['{"title":"', "A conversation", '"}'])
    request = Request.new(body: body, headers: { "content-type" => "application/json" })

    assert_equal({ "title" => "A conversation" }, Rho::ControlServer.json_body(request))
    assert_nil body.read
  end

  def test_the_body_limit_applies_to_all_chunks_and_closes_a_rejected_body
    prefix = '{"text":"'
    suffix = '"}'
    text = "a" * (Rho::ControlServer::MAX_BODY_BYTES - prefix.bytesize - suffix.bytesize)
    accepted = Protocol::HTTP::Body::Buffered.new([prefix, text, suffix])
    request = Request.new(body: accepted, headers: { "content-type" => "application/json" })
    assert_equal text, Rho::ControlServer.json_body(request).fetch("text")

    oversized = Protocol::HTTP::Body::Buffered.new([prefix, text, "x", suffix])
    error = assert_raises(Rho::ControlServer::MalformedBody) do
      Rho::ControlServer.json_body(request.with(body: oversized))
    end
    assert_includes error.message, "exceeds #{Rho::ControlServer::MAX_BODY_BYTES} bytes"
    assert_nil oversized.read, "the framework closes the reader when the bounded read refuses it"
  end
end
