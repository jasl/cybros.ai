require "json"
require "net/http"
require "socket"
require "test_helper"

# Pins response envelopes, streaming and transport errors against local TCP servers.
class TestDefaultAdapter < Minitest::Test
  def test_call_returns_symbol_envelope_with_downcased_headers_and_string_body
    body = '{"ok":true,"id":"resp_1"}'
    requests = Queue.new

    response =
      with_server(canned_json_response(body), requests) do |port|
        adapter.call(
          method: :post,
          url: "http://127.0.0.1:#{port}/v1/chat/completions",
          headers: { "Content-Type" => "application/json", "Authorization" => "Bearer sk-test" },
          body: JSON.generate({ model: "gpt-test", stream: false })
        )
      end

    assert_equal 200, response[:status]
    assert_equal body, response[:body]
    assert_instance_of String, response[:body]
    # Header names come back as downcased strings (Net::HTTP normalization).
    assert_equal "application/json", response.dig(:headers, "content-type")
    assert_equal "abc123", response.dig(:headers, "x-request-id")
    refute response.fetch(:headers).key?("X-Request-Id")
    response.fetch(:headers).each_key do |key|
      assert_instance_of String, key
      assert_equal key.downcase, key
    end

    wire = requests.pop
    assert_includes wire.fetch(:head), "POST /v1/chat/completions HTTP/1.1"
    assert_match(/^authorization: Bearer sk-test\r?$/i, wire.fetch(:head))
    parsed_wire_body = JSON.parse(wire.fetch(:body))
    assert_equal({ "model" => "gpt-test", "stream" => false }, parsed_wire_body)
  end

  def test_call_stream_yields_each_sse_chunk_and_returns_nil_body
    chunks = ["data: {\"n\":1}\n\n", "data: {\"n\":2}\n\n", "data: [DONE]\n\n"]
    requests = Queue.new
    yielded = []

    response =
      with_server(chunked_sse_response(chunks), requests) do |port|
        adapter.call_stream(method: :get, url: "http://127.0.0.1:#{port}/v1/stream") do |chunk|
          yielded << chunk
        end
      end

    # Each transfer-encoding chunk is yielded incrementally as its own block call.
    assert_equal chunks, yielded
    assert_equal 200, response[:status]
    assert_equal "text/event-stream", response.dig(:headers, "content-type")
    # Current contract: streamed SSE bodies are NOT buffered into the envelope.
    assert_nil response[:body]
  end

  def test_call_stream_with_block_buffers_non_event_stream_body_without_yielding
    body = '{"error":{"message":"nope"}}'
    requests = Queue.new
    yielded = []

    response =
      with_server(canned_json_response(body), requests) do |port|
        adapter.call_stream(method: :get, url: "http://127.0.0.1:#{port}/v1/stream") do |chunk|
          yielded << chunk
        end
      end

    assert_equal [], yielded
    assert_equal 200, response[:status]
    assert_equal body, response[:body]
  end

  def test_call_stream_without_block_delegates_to_call
    body = '{"ok":true}'
    requests = Queue.new

    response =
      with_server(canned_json_response(body), requests) do |port|
        adapter.call_stream(method: :get, url: "http://127.0.0.1:#{port}/v1/models")
      end

    assert_equal 200, response[:status]
    assert_equal body, response[:body]
    assert_equal "application/json", response.dig(:headers, "content-type")
  end

  def test_read_timeout_is_applied_and_wraps_as_sdk_timeout_error
    requests = Queue.new

    # Transport failures wrap into the SDK's error vocabulary, matching the
    # HTTPX adapter (a raw Net::ReadTimeout used to leak through here).
    with_server(nil, requests) do |port|
      assert_raises(SimpleInference::TimeoutError) do
        adapter.call(
          method: :post,
          url: "http://127.0.0.1:#{port}/v1/slow",
          headers: { "Content-Type" => "application/json" },
          body: "{}",
          open_timeout: 1,
          read_timeout: 0.1
        )
      end
    end
  end

  def test_connection_refused_wraps_as_sdk_connection_error
    # Grab an ephemeral port and close the listener so nothing accepts.
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    assert_raises(SimpleInference::ConnectionError) do
      adapter.call(method: :get, url: "http://127.0.0.1:#{port}/", headers: {})
    end
  end

  def test_failed_tls_exchange_wraps_as_sdk_connection_error_with_original_cause
    with_failed_tls_exchange do |url|
      error = assert_raises(SimpleInference::ConnectionError) do
        adapter.call(method: :get, url: url, timeout: 2)
      end

      assert_instance_of OpenSSL::SSL::SSLError, error.cause
      assert_equal error.cause.message, error.message
    end
  end

  def test_streaming_failed_tls_exchange_wraps_as_sdk_connection_error_without_yielding
    chunks = []

    with_failed_tls_exchange do |url|
      error = assert_raises(SimpleInference::ConnectionError) do
        adapter.call_stream(method: :get, url: url, timeout: 2) { |chunk| chunks << chunk }
      end

      assert_instance_of OpenSSL::SSL::SSLError, error.cause
      assert_equal error.cause.message, error.message
      assert_empty chunks
    end
  end

  private

  def adapter
    SimpleInference::HTTPAdapters::Default.new
  end

  # A plaintext response to the TLS hello deterministically fails the handshake.
  def with_failed_tls_exchange
    server = TCPServer.new("127.0.0.1", 0)
    listener = Thread.new do
      socket = server.accept
      socket.readpartial(1024)
      socket.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
    ensure
      socket&.close
    end

    yield "https://127.0.0.1:#{server.addr[1]}/"
  ensure
    listener&.kill&.join
    server&.close
  end

  # Serves exactly one connection: captures the wire request into +requests+,
  # then writes +response_bytes+ (or holds the socket open when nil).
  def with_server(response_bytes, requests)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread =
      Thread.new do
        socket = server.accept
        requests << read_http_request(socket)
        response_bytes ? socket.write(response_bytes) : sleep
        socket.close
      end

    yield port
  ensure
    thread&.kill
    server&.close
  end

  def read_http_request(socket)
    buffer = +""
    buffer << socket.readpartial(4096) until buffer.include?("\r\n\r\n")
    head, _separator, tail = buffer.partition("\r\n\r\n")
    content_length = head[/^content-length:\s*(\d+)/i, 1].to_i
    body = tail.dup
    body << socket.read(content_length - body.bytesize) if content_length > body.bytesize
    { head: head, body: body }
  end

  def canned_json_response(body)
    headers =
      "Content-Type: application/json\r\n" \
      "X-Request-Id: abc123\r\n" \
      "Content-Length: #{body.bytesize}\r\n" \
      "Connection: close\r\n"

    "HTTP/1.1 200 OK\r\n#{headers}\r\n#{body}"
  end

  def chunked_sse_response(chunks)
    encoded = chunks.map { |chunk| "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n" }.join

    "HTTP/1.1 200 OK\r\n" \
      "Content-Type: text/event-stream\r\n" \
      "Transfer-Encoding: chunked\r\n" \
      "Connection: close\r\n" \
      "\r\n#{encoded}0\r\n\r\n"
  end
end
