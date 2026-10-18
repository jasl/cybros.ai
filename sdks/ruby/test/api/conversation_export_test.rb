require "test_helper"
require "socket"
require "stringio"
require "zlib"

class ApiConversationExportTest < Minitest::Test
  PATH = "/agent_api/v1/workspaces/workspace/conversations/conversation/export".freeze

  def test_native_download_keeps_gzip_bytes_and_the_caller_owns_the_sink
    text = "#{JSON.generate(type: "export")}\n#{JSON.generate(type: "end")}\n"
    compressed = Zlib.gzip(text)
    with_response("200 OK", compressed, "application/gzip") do |chat, request|
      sink = StringIO.new("".b)
      response = chat.export(sink)

      assert_instance_of CybrosAgent::Response, response
      assert_equal 200, response.status
      assert_nil response.body
      assert_equal "application/gzip", response.headers["content-type"]
      assert_equal compressed, sink.string
      assert_equal text, Zlib.gunzip(sink.string)
      refute_predicate sink, :closed?
      assert_request(request.value)
    end
  end

  def test_a_refusal_preserves_the_api_error_and_writes_nothing
    body = JSON.generate(error: { code: "not_found", message: "Not found" })
    with_response("404 Not Found", body, "application/json") do |chat, request|
      sink = StringIO.new("".b)
      error = assert_raises(CybrosAgent::Api::NotFound) { chat.export(sink) }

      assert_equal "not_found", error.code
      assert_empty sink.string
      refute_predicate sink, :closed?
      assert_request(request.value)
    end
  end

  private

    def with_response(status, body, content_type)
      TCPServer.open("127.0.0.1", 0) do |server|
        thread = Thread.new do
          raise "client never connected" unless IO.select([server], nil, nil, 5)

          socket = server.accept
          request = +""
          request << socket.readpartial(1024) until request.include?("\r\n\r\n")
          socket.write("HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\n" \
            "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          socket.write(body)
          request
        ensure
          socket&.close
        end
        client = CybrosAgent::Client.new(base_url: "http://127.0.0.1:#{server.local_address.ip_port}",
          credential: "member-fixture", request_timeout: 5)
        yield client.workspace("workspace").conversation("conversation"), thread
      ensure
        thread&.kill
        thread&.join
      end
    end

    def assert_request(request)
      assert_match %r{\AGET #{PATH} HTTP/1.1\r\n}, request
      assert_match(/authorization: Bearer member-fixture/i, request)
      refute_match(/\r\n(?:range|if-none-match):/i, request)
    end
end
