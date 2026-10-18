module Mcp
  # The OAuth library owns protocol discovery and exchange. This adapter owns
  # bounded wire IO and never redirects or retries a single-use grant.
  class OAuthHttpClient
    MAX_TIMEOUT_SECONDS = 30
    MAX_RESPONSE_BYTES = 1_048_576
    Response = Data.define(:status, :body, :headers)
    # The library fills these mutable request handles before dispatch.
    Request = Struct.new(:headers, :body, :options, keyword_init: true)
    Options = Struct.new(:on_data, keyword_init: true)

    attr_reader :request_sent

    def initialize(timeout_seconds: MAX_TIMEOUT_SECONDS)
      timeout = [Float(timeout_seconds), MAX_TIMEOUT_SECONDS].min
      raise Error.new(:mcp_timeout) unless timeout.finite? && timeout.positive?

      @deadline = monotonic_time + timeout
      @request_sent = false
      @session = HTTPX.plugin(:ssrf_filter).plugin(:stream).plugin(HttpTransport::FixedOrigin)
        .plugin(Nexus::HttpDeadline).with(persistent: false, debug: nil, debug_redact: true)
    end

    def get(url, &block) = exchange("GET", url, &block)
    def post(url, &block) = exchange("POST", url, &block)

    def close
      @session.close
    rescue HTTPX::Error, SystemCallError, IOError
      nil
    end

    private

      def exchange(verb, url)
        uri = Nexus::McpEndpoint.parse(url)
        request = Request.new(headers: {}, body: nil, options: Options.new)
        yield request
        remaining = remaining_time
        stream = @session.request(verb, uri, headers: request.headers, body: request.body,
          stream: true, timeout: { connect_timeout: [5, remaining].min,
            request_timeout: remaining, read_timeout: remaining,
            write_timeout: remaining, operation_timeout: remaining })
        stream.request.on(:headers) { @request_sent = true if verb == "POST" }
        read_response(stream, request.options.on_data)
      rescue Nexus::McpEndpoint::Invalid
        raise failure(:mcp_invalid_endpoint), cause: nil
      rescue HTTPX::ServerSideRequestForgeryError
        raise failure(:mcp_endpoint_refused), cause: nil
      rescue HTTPX::TimeoutError
        raise failure(:mcp_timeout), cause: nil
      rescue HTTPX::Error, SystemCallError, IOError, URI::InvalidURIError
        raise failure(:mcp_transport_error), cause: nil
      end

      def read_response(stream, on_data)
        body = +""
        begin
          stream.each do |chunk|
            remaining_time
            body << chunk
            raise failure(:mcp_response_too_large) if body.bytesize > MAX_RESPONSE_BYTES

            on_data&.call(chunk, body.bytesize, nil)
          end
        rescue HTTPX::HTTPError
          # OAuth uses ordinary 4xx bodies (for example invalid_grant). The
          # stream has already delivered the bounded body before this verdict.
          nil
        end
        status = stream.request.response.status
        raise failure(:mcp_redirect_refused) if (300..399).cover?(status)

        Response.new(status: status, body: body, headers: stream.request.response.headers.to_h)
      end

      def remaining_time
        remaining = @deadline - monotonic_time
        raise failure(:mcp_timeout) unless remaining.positive?

        remaining
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def failure(code) = Error.new(code, request_sent: request_sent)
  end
end
