module SimpleInference
  class Error < StandardError
    # Whether the provider said it is overloaded right now — a fact about the
    # provider's load, never the caller's quota (a 429 is not overload).
    def overloaded? = false
  end

  class CapabilityError < Error; end

  class ValidationError < Error; end

  # A deterministic zero-IO cap rejection: the measured value exceeds the
  # surface's selectable cap. Raised before any request body or IO exists.
  class BoundExceededError < ValidationError; end

  class ConfigurationError < ValidationError; end

  class HTTPError < Error
    attr_reader :response

    def initialize(message, response:)
      super(message)
      @response = response
    end

    def status = @response.status

    def headers = @response.headers

    def body = @response.body

    def raw_body = @response.raw_body

    # 503 (service unavailable) and Anthropic's 529 (overloaded).
    OVERLOADED_STATUSES = [503, 529].freeze

    def overloaded? = OVERLOADED_STATUSES.include?(status.to_i)
  end

  class TimeoutError < Error; end
  class ConnectionError < Error; end

  # The connection was never established, so NO REQUEST BYTES WERE WRITTEN.
  #
  # It is a subclass so every existing `rescue ConnectionError` keeps working;
  # what it adds is the one distinction a caller cannot make for itself. Only
  # an adapter may raise it, and only where the underlying library says so in
  # its own class — HTTPX raises `ConnectTimeoutError` strictly while its
  # connection state machine is still connecting, before any request framing.
  # A caller that tried to recover the same fact by matching error classes or
  # messages would be wrong, because the ordinary `ConnectionError` also folds
  # in `IOError`, `SystemCallError`, and post-send `HTTPX::Error`s — losses
  # that happen AFTER bytes went out.
  #
  # The async lane cannot raise this and must not pretend to: its client is
  # built lazily, so the connection happens inside the call, under the one
  # rescue that covers everything after it too.
  class ConnectionNotEstablishedError < ConnectionError; end
  class DecodeError < Error; end

  # A stream-lifecycle violation: consuming a Stream twice, or asking an
  # INTERRUPTED stream (consumption broke off mid-way) for its final result.
  class StreamError < Error; end

  # A provider-STARTED stream (2xx, SSE) that ended WITHOUT its lane's
  # terminal event (response.completed/incomplete/failed, message_stop, a
  # finishReason chunk, a finish_reason chunk). Unlike a consumer interrupt,
  # the provider ended this stream without a valid terminal. events_seen and
  # last_event_type are adapter-observable diagnostics.
  class ProviderStreamInterruptedError < StreamError
    attr_reader :events_seen, :last_event_type

    def initialize(message, events_seen: nil, last_event_type: nil)
      super(message)
      @events_seen = events_seen
      @last_event_type = last_event_type
    end
  end
end
