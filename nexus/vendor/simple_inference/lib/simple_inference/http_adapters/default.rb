require "net/http"
require "openssl"
require "uri"

require_relative "../internal/envelope"

module SimpleInference
  module HTTPAdapters
    # Default synchronous HTTP adapter built on Net::HTTP.
    # It is compatible with Ruby 3 Fiber scheduler and keeps the interface
    # minimal so it can be swapped out for custom adapters (HTTPX, async-http, etc.).
    class Default < HTTPAdapter
      def call(request)
        http, req = build_request(request)

        response = wrap_transport_errors { http.request(req) }

        {
          status: Integer(response.code),
          headers: response.each_header.to_h,
          body: response.body.to_s,
        }
      end

      # Streaming-capable request helper.
      #
      # When the response is `text/event-stream` (and 2xx), it yields raw body chunks
      # as they arrive via the given block, and returns a response hash with `body: nil`.
      #
      # For non-streaming responses, it behaves like `#call` and returns the full body.
      def call_stream(request)
        return call(request) unless block_given?

        http, req = build_request(request)

        status = nil
        response_headers = {}
        response_body = +""

        wrap_transport_errors do
          http.request(req) do |response|
            status = Integer(response.code)
            response_headers = response.each_header.to_h

            if Internal::Envelope.new(status: status, headers: response_headers, body: nil).sse?
              response.read_body do |chunk|
                yield chunk
              end
              response_body = nil
            else
              response_body = response.body.to_s
            end
          end
        end

        {
          status: Integer(status),
          headers: response_headers,
          body: response_body,
        }
      end

      private

      # Wrap transport failures in the SDK's error vocabulary, matching the
      # HTTPX adapter — callers rescuing SimpleInference::TimeoutError /
      # ConnectionError must receive the same failures, including TLS handshakes.
      def wrap_transport_errors
        yield
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise SimpleInference::TimeoutError, e.message
      rescue SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError => e
        raise SimpleInference::ConnectionError, e.message
      end

      def build_request(request)
        uri = URI.parse(request.fetch(:url))

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"

        apply_timeouts(http, request)

        req = http_class_for(request[:method]).new(uri.request_uri)
        apply_headers(req, request[:headers] || {})
        apply_body(req, request[:body])

        [http, req]
      end

      def apply_timeouts(http, request)
        timeout = request[:timeout]
        open_timeout = request[:open_timeout] || timeout
        read_timeout = request[:read_timeout] || timeout

        http.open_timeout = open_timeout if open_timeout
        http.read_timeout = read_timeout if read_timeout
      end

      def apply_headers(req, headers)
        headers.each do |key, value|
          req[key.to_s] = value
        end
      end

      def apply_body(req, body)
        return unless body

        req.body = body.to_s
      end

      def http_class_for(method)
        case method.to_s.upcase
        when "GET"    then Net::HTTP::Get
        when "POST"   then Net::HTTP::Post
        when "PUT"    then Net::HTTP::Put
        when "PATCH"  then Net::HTTP::Patch
        when "DELETE" then Net::HTTP::Delete
        else
          raise ArgumentError, "Unsupported HTTP method: #{method.inspect}"
        end
      end
    end
  end
end
