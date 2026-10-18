require "test_helper"
require "resolv"
require "socket"
require "stringio"

class HttpTransportResolutionTest < Minitest::Test
  # A replaced service can acquire a new address before its old DNS TTL
  # expires. Use real DNS and HTTP sockets, with both addresses on loopback.
  def test_a_later_call_resolves_a_replaced_service_after_a_connection_failure
    [{}, { sink: StringIO.new, accept: CybrosAgent::ANY_MEDIA }].each_with_index do |options, index|
      with_service("replacement-#{index}.test") do |service, transport|
        assert_equal 200, transport.call("/receipt", timeout: 2, **options).status
        first_queries = service.queries.length
        assert_equal 200, transport.call("/receipt", timeout: 2, **options).status
        initial_queries = service.queries.length
        assert_equal first_queries, initial_queries, "healthy calls retain DNS caching"

        service.replace
        assert_raises(CybrosAgent::TransportError) do
          transport.call("/receipt", timeout: 2, **options)
        end
        assert_equal 2, service.requests.length, "a failed call is never automatically replayed"

        assert_equal 200, transport.call("/receipt", timeout: 2, **options).status
        assert_operator service.queries.length, :>, initial_queries
        recovered_queries = service.queries.length
        assert_equal 200, transport.call("/receipt", timeout: 2, **options).status
        assert_equal recovered_queries, service.queries.length, "healthy calls retain DNS caching"
        assert_equal 4, service.requests.length
      end
    end
  end

  def test_an_uncertain_post_is_not_replayed_when_its_connection_drops
    with_service("uncertain-post.test") do |service, transport|
      service.drop_next_response

      error = assert_raises(CybrosAgent::TransportError) do
        transport.call("/write", method: :post, body: { "value" => "once" }, timeout: 2)
      end

      refute_kind_of CybrosAgent::RequestNotSentError, error
      assert_equal ["POST /write HTTP/1.1"], service.requests
      assert_equal 200, transport.call("/receipt", timeout: 2).status
      assert_equal ["POST /write HTTP/1.1", "GET /receipt HTTP/1.1"], service.requests
    end
  end

  private

    def with_service(hostname)
      service = Service.new
      transport = CybrosAgent::HttpTransport.new(base_url: "http://#{hostname}:#{service.port}")
      session = transport.instance_variable_get(:@session)
      transport.instance_variable_set(:@session, session.with(
        resolver_options: { nameserver: [["127.0.0.1", service.dns_port]] },
        ip_families: [Socket::AF_INET, Socket::AF_INET6]
      ))
      yield(service, transport)
    ensure
      service&.close
    end

  class Service
    attr_reader :queries, :requests, :port

    def initialize
      @queries, @requests = [], []
      @address = "127.0.0.1"
      @server = TCPServer.new(@address, 0)
      @port = @server.local_address.ip_port
      @dns = UDPSocket.new
      @dns.bind("127.0.0.1", 0)
      @dns_thread = Thread.new { serve_dns }
      @http_thread = Thread.new { serve_http }
    end

    def dns_port = @dns.local_address.ip_port
    def drop_next_response = @drop_response = true

    def replace
      @server.close
      @http_thread.value
      @address = "::1"
      @server = TCPServer.new(@address, @port)
      @http_thread = Thread.new { serve_http }
    end

    def close
      @server.close
      @dns.close
      @http_thread.value
      @dns_thread.value
    end

    private

      def serve_dns
        loop do
          bytes, sender = @dns.recvfrom(4096)
          query = Resolv::DNS::Message.decode(bytes)
          response = Resolv::DNS::Message.new(query.id)
          response.qr = response.aa = 1
          query.each_question do |name, type|
            @queries << [name.to_s, type]
            response.add_question(name, type)
            if (@address == "127.0.0.1" && type == Resolv::DNS::Resource::IN::A) ||
                (@address == "::1" && type == Resolv::DNS::Resource::IN::AAAA)
              response.add_answer(name, 600, type.new(@address))
            end
          end
          @dns.send(response.encode, 0, sender[3], sender[1])
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def serve_http
        loop do
          socket = @server.accept
          begin
            request = +""
            request << socket.readpartial(1024) until request.include?("\r\n\r\n")
            headers, body = request.split("\r\n\r\n", 2)
            length = headers[/\r\ncontent-length:\s*(\d+)/i, 1].to_i
            body << socket.readpartial(1024) while body.bytesize < length
            @requests << headers.lines.first.strip
            if @drop_response
              @drop_response = false
            else
              socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            end
          ensure
            socket.close
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end
  end
end
