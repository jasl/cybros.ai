begin
  require "httpx"
rescue LoadError => e
  raise LoadError,
        "httpx gem is required for SimpleInference::HTTPAdapters::HTTPX (add `gem \"httpx\"`)",
        cause: e
end

require_relative "../internal/envelope"

# HTTPX's stream plugin expects all request objects to respond to `#stream`,
# however some internal requests (e.g. proxy CONNECT) don't include the plugin's
# RequestMethods. Add a harmless accessor at the base class level.
unless ::HTTPX::Request.method_defined?(:stream) && ::HTTPX::Request.method_defined?(:stream=)
  ::HTTPX::Request.class_eval do
    attr_accessor :stream
  end
end

module SimpleInference
  module HTTPAdapters
    # Fiber-friendly HTTP adapter built on HTTPX.
    class HTTPX < HTTPAdapter
      # HTTPX's own streaming default, restated because this adapter now owns
      # the mapping (see #timeout_options): the plugin installs
      # `operation_timeout: 60` and a caller that names no idle bound keeps it.
      STREAM_OPERATION_TIMEOUT = 60
      # The TCP/TLS establishment ceiling when a caller names none — HTTPX's
      # own default, restated because this adapter passes `connect_timeout`
      # explicitly and would otherwise override that default with the whole
      # lane deadline. A blackholed connect must not cost 600 seconds of a
      # held fiber and a held capacity slot.
      CONNECT_TIMEOUT = 60

      class << self
        def default_client
          # HTTPX's persistent plugin loads fiber_concurrency in current
          # releases (verified through 1.8.x). That makes the session
          # compatible with scheduler-managed fibers without forcing the
          # application to install a scheduler.
          #
          # C2-1 entry resolution R1: the persistent plugin implicitly loads
          # :retries with max_retries: 1 and overrides retryable_request? so
          # even non-idempotent POSTs silently re-send once on reconnectable
          # connection errors — a hidden adapter retry the no-hidden-retry
          # truth table forbids (a paid inference call could double-bill).
          # This IS the one production synchronous session config: connection
          # persistence retained, implicit retry neutralized to zero. Re-check
          # the plugin's retry defaults at every httpx version bump (register
          # watch item).
          @default_client ||= ::HTTPX.plugin(:persistent).with(max_retries: 0)
        end

        # HTTPX `Session#with` and `Session#plugin` branch a NEW session with
        # its own connection pool, so deriving per request would defeat the
        # persistent plugin entirely (every provider call would pay
        # DNS+TCP+TLS) and leak per-thread selector-store entries. Timeout
        # tuples come from a small fixed set of configured deadlines, so the
        # cache stays bounded.
        DERIVED_SESSIONS_MUTEX = Mutex.new

        def derived_session(base, timeout_opts:)
          key = [base.object_id, timeout_opts]
          DERIVED_SESSIONS_MUTEX.synchronize do
            @derived_sessions ||= {}
            @derived_sessions[key] ||= timeout_opts.empty? ? base : base.with(timeout: timeout_opts)
          end
        end

        # `Session#with` always branches a fresh connection pool. Internal
        # one-shot sessions therefore exist only inside this block API: the
        # adapter, never its caller, owns closing them on every return/raise.
        def with_derived_session(base, timeout_opts:)
          session = base.with(timeout: timeout_opts)
          begin
            yield session
          ensure
            close_resource(session)
          end
        end

        # Streams get a private one-shot session: a shared session funnels
        # same-origin requests onto one connection, which serializes
        # concurrent HTTP/1.1 streams entirely (Connection#match? ignores
        # in-flight work), and an aborted stream can poison a shared
        # persistent pool. An injected base remains caller-owned; only its
        # derived child is closed here.
        def with_stream_session(timeout_opts:, base: nil)
          base ||= (@stream_session_base ||= ::HTTPX.plugin(:stream))
          with_derived_session(base, timeout_opts: timeout_opts) do |session|
            yield session
          end
        end

        private

        def close_resource(resource)
          resource.close
        rescue StandardError
          nil
        end
      end

      # client: session for non-streaming calls (connection reuse pays off
      # there); stream_client: optional session override for streams — when
      # absent every stream gets a private one-shot session (see
      # .with_stream_session for why streams must not share connections).
      def initialize(timeout: nil, client: nil, stream_client: nil, request_timeout_cap: nil)
        @timeout = timeout
        unless request_timeout_cap.nil? || request_timeout_cap.respond_to?(:call)
          raise SimpleInference::ConfigurationError, "request_timeout_cap must be callable"
        end
        @request_timeout_cap = request_timeout_cap
        client ||= self.class.default_client

        [client, stream_client].compact.each do |candidate|
          next if candidate == ::HTTPX || candidate.is_a?(::HTTPX::Session)

          raise SimpleInference::ConfigurationError,
                "client must be ::HTTPX or an instance of ::HTTPX::Session (got #{candidate.class})"
        end

        @client = client
        @stream_client = stream_client
      end

      def call(request)
        method, url, headers, body = unpack_request(request)
        if @request_timeout_cap
          # Request-specific options join HTTPX connection matching, so a
          # changing cap may not ride the shared persistent pool. Derive and
          # own a one-shot child FIRST, then resolve the cap in the request
          # argument list — the final Ruby boundary before HTTPX sends.
          self.class.with_derived_session(@client, timeout_opts: {}) do |client|
            response = client.request(
              method, url, headers: headers, body: body,
              timeout: timeout_options(request, stream: false)
            )
            response_envelope(response)
          end
        else
          client = self.class.derived_session(
            @client, timeout_opts: timeout_options(request, stream: false)
          )
          response_envelope(client.request(method, url, headers: headers, body: body))
        end
      rescue ::HTTPX::ConnectTimeoutError => e
        raise SimpleInference::ConnectionNotEstablishedError, e.message
      rescue ::HTTPX::TimeoutError => e
        raise SimpleInference::TimeoutError, e.message
      rescue ::HTTPX::Error, IOError, SystemCallError => e
        raise SimpleInference::ConnectionError, e.message
      end

      def call_stream(request)
        return call(request) unless block_given?

        method, url, headers, body = unpack_request(request)
        # ALWAYS per-request, never on the session: the stream plugin rewrites
        # the session's whole timeout hash when it builds the request, so a
        # bound installed there is silently replaced by the plugin's defaults.
        # The dynamic cap resolves here too, after the one-shot session exists
        # and immediately before HTTPX sends.
        self.class.with_stream_session(timeout_opts: {}, base: @stream_client) do |client|
          # Resolved INSIDE the block, after the one-shot session exists: a
          # dynamic cap may raise at deadline equality, and it must do so with
          # the session already owned so the ensure closes it and no HTTPX
          # request has been issued.
          deadline = stream_deadline(request)
          stream_response = client.request(
            method, url, headers: headers, body: body, stream: true,
            timeout: timeout_options(request, stream: true)
          )
          with_stream_response(stream_response) do
            stream_response_envelope(stream_response) do |chunk|
              deadline.check
              yield chunk
            end
          end
        end
      rescue ::HTTPX::ConnectTimeoutError => e
        raise SimpleInference::ConnectionNotEstablishedError, e.message
      rescue ::HTTPX::TimeoutError => e
        raise SimpleInference::TimeoutError, e.message
      rescue ::HTTPX::Error, IOError, SystemCallError => e
        raise SimpleInference::ConnectionError, e.message
      end

      private

      def unpack_request(request)
        [
          request.fetch(:method).to_s.downcase.to_sym,
          request.fetch(:url),
          request[:headers] || {},
          request[:body],
        ]
      end

      def response_envelope(response)
        with_response(response) do
          guard_error_response(response)
          {
            status: response.status.to_i,
            headers: normalize_headers(response),
            body: response.body.to_s,
          }
        end
      end

      def with_response(response)
        yield response
      ensure
        close_resource(response)
      end

      def with_stream_response(stream_response)
        yield stream_response
      ensure
        response = stream_response
        if stream_response.respond_to?(:request) && stream_response.request.respond_to?(:response)
          response = stream_response.request.response
        end
        close_resource(response)
      end

      def close_resource(resource)
        resource&.close
      rescue StandardError
        nil
      end

      def stream_response_envelope(stream_response)
        guard_error_response(stream_response)

        streaming = nil
        response_headers = {}
        status = nil
        full_body = +"".b

        begin
          stream_response.each do |chunk|
            status ||= stream_response.status.to_i
            response_headers = normalize_headers(stream_response) if response_headers.empty?
            streaming = streamable_sse?(status, response_headers) if streaming.nil?

            if streaming
              yield chunk
            else
              full_body << chunk.to_s
            end
          end
        rescue ::HTTPX::HTTPError => e
          # HTTPX's stream plugin raises for non-2xx. Swallow it and let the SDK
          # raise `SimpleInference::HTTPError` based on status.
          status ||= e.response.status.to_i
          response_headers = normalize_headers(e.response) if response_headers.empty?
        end

        status ||= stream_response.status.to_i
        response_headers = normalize_headers(stream_response) if response_headers.empty?

        if streamable_sse?(status, response_headers)
          { status: status, headers: response_headers, body: nil }
        else
          { status: status, headers: response_headers, body: full_body.to_s }
        end
      end

      # Mirror the SDK's timeout semantics:
      # - `:timeout` is the overall request deadline
      # - `:open_timeout` and `:read_timeout` override connect/idle deadlines
      #
      # **THE TWO PATHS MAP THESE DIFFERENTLY, because HTTPX makes an idle
      # bound and a total deadline mutually exclusive on a stream.** Two facts
      # in httpx 1.8.1, both verified against the installed gem:
      #
      # 1. The stream plugin merges `{read_timeout: Infinity,
      #    operation_timeout: 60}` OVER the SESSION's options when it builds a
      #    streaming request (plugins/stream.rb STREAM_REQUEST_OPTIONS +
      #    Options#merge, where the argument wins per key). Both keys are in
      #    that hash, so neither survives at session level. Only PER-REQUEST
      #    params get past it.
      # 2. `connection.rb`: `when OperationTimeoutError / next unless
      #    request.active_timeouts.empty?` — an operation timeout is SWALLOWED
      #    while any request-level timer is armed, and `request_timeout` and
      #    `total_request_timeout` are both armed at `:headers`.
      #
      # So a stream gets `operation_timeout` (the caller's idle bound, which is
      # what "the provider accepted and went quiet" actually is) and NO
      # request-level timer at all; its total deadline is enforced by
      # #stream_deadline in this adapter, one check per chunk. Unary keeps
      # HTTPX's own `request_timeout`/`read_timeout`, where they mean what they
      # say and nothing overrides them.
      def timeout_options(request, stream:)
        cap = resolved_request_timeout_cap
        timeout = capped_timeout(request[:timeout] || @timeout, cap)
        open_timeout = capped_timeout(
          request[:open_timeout] || (timeout && [timeout, CONNECT_TIMEOUT].min), cap
        )

        timeout_opts = {}
        timeout_opts[:connect_timeout] = open_timeout.to_f if open_timeout
        return timeout_opts.merge(stream_idle_options(request, cap)) if stream

        timeout_opts[:request_timeout] = timeout.to_f if timeout
        read_timeout = capped_timeout(request[:read_timeout] || timeout, cap)
        timeout_opts[:read_timeout] = read_timeout.to_f if read_timeout
        timeout_opts
      end

      # The default is the plugin's own, and it is resolved BEFORE the cap so
      # a caller that owns an absolute deadline clamps the idle bound too: an
      # idle wait longer than the time left is not a bound anyone asked for.
      def stream_idle_options(request, cap)
        idle = request[:read_timeout] || STREAM_OPERATION_TIMEOUT
        { operation_timeout: capped_timeout(idle, cap).to_f }
      end

      # The stream's TOTAL bound, enforced here because HTTPX cannot hold it
      # and the idle bound at the same time (see #timeout_options). One
      # monotonic comparison per chunk: a provider that trickles forever is
      # stopped at the deadline, and one that goes silent is stopped earlier
      # by `operation_timeout`. Between them the two failure shapes are both
      # covered, which neither library timer does alone.
      def stream_deadline(request)
        total = capped_timeout(request[:timeout] || @timeout, resolved_request_timeout_cap)
        StreamDeadline.new(total&.to_f)
      end

      class StreamDeadline
        def initialize(seconds)
          @seconds = seconds
          @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def check
          return if @seconds.nil?

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
          return if elapsed <= @seconds

          raise SimpleInference::TimeoutError,
                "streamed response exceeded its #{@seconds}s deadline after #{elapsed.round(1)}s"
        end
      end

      # Opt-in dynamic cap used by callers that own an absolute deadline.
      # Resolved in the one-shot session's request argument list, after
      # session derivation and immediately before HTTPX sends. The callback
      # may raise a typed caller error at equality; the block-owned session
      # still closes and no HTTPX request has been issued.
      def resolved_request_timeout_cap
        return nil if @request_timeout_cap.nil?

        cap = Float(@request_timeout_cap.call)
        return cap if cap.finite? && cap.positive?

        raise SimpleInference::ConfigurationError,
              "request_timeout_cap must return a positive finite number"
      rescue ArgumentError, TypeError
        raise SimpleInference::ConfigurationError,
              "request_timeout_cap must return a positive finite number"
      end

      def capped_timeout(value, cap)
        return value if cap.nil?
        return cap if value.nil?

        [value.to_f, cap].min
      end

      # HTTPX may return an error response object instead of raising.
      #
      # NOTE: Some error response objects do not expose the normal response API
      # (e.g. no `#headers`), so we must handle them explicitly.
      def guard_error_response(response)
        if response.is_a?(::HTTPX::ErrorResponse)
          # The same distinction the rescues above make, on the path where
          # HTTPX RETURNS its failure instead of raising it. Missing it here
          # would make the not-sent answer depend on which of two equivalent
          # HTTPX modes produced the failure.
          error_class =
            if response.error.is_a?(::HTTPX::ConnectTimeoutError)
              SimpleInference::ConnectionNotEstablishedError
            else
              SimpleInference::ConnectionError
            end
          raise error_class, (response.error&.message || "HTTPX request failed")
        end

        return unless response.status.to_i == 0

        raise SimpleInference::ConnectionError, "HTTPX request failed"
      end

      def normalize_headers(response)
        response.headers.to_h.each_with_object({}) do |(k, v), out|
          out[k.to_s] = v.is_a?(Array) ? v.join(", ") : v.to_s
        end
      end

      def streamable_sse?(status, headers)
        Internal::Envelope.new(status: status.to_i, headers: headers, body: nil).sse?
      end
    end
  end
end
