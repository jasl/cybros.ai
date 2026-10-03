require "httpx"
require "json"
require "uri"
require_relative "http_deadline"

module CybrosAgent
  # The one httpx transport behind the API clients and the device flow. The
  # bearer is a header set per request, not httpx's :auth plugin, which
  # memoises the token and would keep presenting a rotated-out one.
  class HttpTransport
    DEFAULT_OPERATION_TIMEOUT = 30
    TOTAL_TIMEOUT_MULTIPLIER = 4
    METHODS = %i[get post patch put delete].freeze
    REQUEST_NOT_SENT_ERRORS = [
      HTTPX::ConnectTimeoutError,
      HTTPX::ConnectionError,
      HTTPX::PoolTimeoutError,
      HTTPX::ResolveError,
      HTTPX::ResolveTimeoutError,
      HTTPX::SettingsTimeoutError,
      HTTPX::TLSError,
      HTTPX::TotalRequestTimeoutError,
    ].freeze
    # The failures httpx raises RAW, outside its ErrorResponse path: a
    # refused connect on the FIRST resolved address (`::1` for a `localhost`
    # URL against a 127.0.0.1-bound kernel — an ordinary dev setup) comes up
    # from the selector as the bare Errno, and a socket torn down under a
    # streamed body the same way. Each is a transport failure to the caller,
    # whose whole retry policy reads TransportError (rho's until and
    # maintenance loops rescue nothing else); none says whether bytes were
    # sent, so none is RequestNotSentError.
    RAW_TRANSPORT_ERRORS = [SystemCallError, SocketError, IOError].freeze

    def initialize(base_url:, timeout: DEFAULT_OPERATION_TIMEOUT)
      base = URI(base_url.to_s.chomp("/"))
      @operation_timeout = positive_timeout(timeout)
      @session = HTTPX.plugin(HttpDeadline).with(
        origin: base,
        base_path: base.path,
        debug_redact: true,
        timeout: {
          operation_timeout: timeout,
          total_request_timeout: timeout * TOTAL_TIMEOUT_MULTIPLIER,
        }
      )
    end

    # Resolve, connect and TLS all run before httpx's total-request timer
    # starts, so each phase is capped by the call's own budget. A `form:`
    # holding a file streams as multipart with httpx owning the boundary.
    # A `sink:` (an IO) streams the RESPONSE body into it chunk by chunk
    # through httpx's stream plugin — the bytes read never
    # holds a 100 MB capture in memory — and the Response then carries no
    # body; a refusal's JSON envelope still comes back as a body, since an
    # error is read whole. Passed only by a caller that streams, the
    # `form:` rule: a transport written before it answers no such keyword.
    def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {},
             timeout:, accept: JSON_MEDIA, sink: nil)
      timeout = positive_timeout(timeout)
      raise ArgumentError, "unsupported method #{method.inspect}" unless METHODS.include?(method)

      request = {
        headers: request_headers(credential:, body:, headers:, accept:),
        timeout: phase_timeouts(timeout),
        resolver_options: { timeouts: bounded_resolve_timeouts(timeout) },
        **{ json: body, form:, params: }.compact,
      }
      return streamed(method, path, request, sink) if sink

      response = @session.request(method, path, **request)
      raise transport_error(response) if response.is_a?(HTTPX::ErrorResponse)

      Response.new(status: response.status, headers: response.headers, body: read(response, accept:))
    rescue *RAW_TRANSPORT_ERRORS => error
      raise TransportError, "#{error.class}: #{error.message}"
    end

    private

      # The stream plugin yields each chunk as it lands; a success is
      # written to the sink and a failure — any status the ladder maps —
      # is read whole so the caller's `failure` sees its envelope.
      def streamed(method, path, request, sink)
        response = stream_session.request(method, path, **request, stream: true)
        raise transport_error(response) if response.is_a?(HTTPX::ErrorResponse)

        begin
          status, bodiless = streamed_status(response)
          if (200..299).cover?(status)
            response.each { |chunk| sink.write(chunk) } unless bodiless
            Response.new(status: status, headers: response.headers, body: nil)
          else
            Response.new(status: status, headers: response.headers,
              body: bodiless ? nil : streamed_envelope(response))
          end
        rescue HTTPX::HTTPError
          raise
        rescue HTTPX::Error
          # The stream enumerator raises the failure stored on its request.
          # Reuse its dispatch state, without retaining an unscrubbed cause.
          raise transport_error(response.request.response), cause: nil
        end
      end

      # A streamed refusal's envelope: with the stream plugin on, httpx
      # hands every chunk to the stream and stores none of the body, so
      # `body.to_s` is empty and the failure ladder would build a code-less
      # error — the JSON is read off the chunks instead. The plugin ends a
      # 4xx/5xx stream with its own `raise_for_status`, after the last
      # chunk: that error is the end of the stream, the status is already
      # ours.
      def streamed_envelope(response)
        chunks = []
        begin
          response.each { |chunk| chunks << chunk }
        rescue HTTPX::HTTPError
          nil
        end
        parse(chunks.join, accept: JSON_MEDIA)
      end

      # httpx's stream plugin answers the status once the first chunk has
      # landed, and an answer with no body — the 304 of a conditional read,
      # an empty file — ends the stream before any chunk: the plugin's
      # enumerator raises StopIteration through `status`. The request has
      # finished by then, so the second ask reads the status off it; and
      # there is nothing left to stream or read — a further `each` would
      # send the request AGAIN, so the caller is told.
      def streamed_status(response)
        [response.status, false]
      rescue StopIteration
        [response.status, true]
      end

      def stream_session
        @stream_session ||= @session.plugin(:stream)
      end

      # The credential's Authorization is merged last: a caller can add
      # Idempotency-Key, but never speak as a different principal.
      def request_headers(credential:, body:, headers:, accept:)
        base = { "Accept" => accept }
        base["Content-Type"] = JSON_MEDIA unless body.nil?
        base = base.merge(headers)
        credential.nil? ? base : base.merge("Authorization" => "Bearer #{credential}")
      end

      def phase_timeouts(timeout)
        {
          connect_timeout: [HTTPX::Options::CONNECT_TIMEOUT, timeout].min,
          settings_timeout: [HTTPX::Options::SETTINGS_TIMEOUT, timeout].min,
          operation_timeout: [@operation_timeout, timeout].min,
          total_request_timeout: timeout,
        }
      end

      def bounded_resolve_timeouts(timeout)
        remaining = timeout
        HTTPX::Resolver::RESOLVE_TIMEOUT.filter_map do |default_timeout|
          if remaining.positive?
            bounded_timeout = [default_timeout, remaining].min
            remaining -= bounded_timeout
            bounded_timeout
          end
        end
      end

      def positive_timeout(timeout)
        unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
          raise ArgumentError, "timeout must be finite and positive"
        end

        timeout
      end

      def transport_error(response)
        error = response.error
        unsent = !response.request.started? && REQUEST_NOT_SENT_ERRORS.any? { |kind| error.is_a?(kind) }
        (unsent ? RequestNotSentError : TransportError).new(error.message)
      end

      # A non-JSON or empty body is not a transport failure: the status ladder
      # classifies it and the client raises MalformedResponse when a success
      # needed a payload it did not get.
      def read(response, accept:) = parse(response.body.to_s, accept: accept)

      def parse(body, accept:)
        return nil if body.empty?
        return body.b unless accept == JSON_MEDIA

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
  end
end
