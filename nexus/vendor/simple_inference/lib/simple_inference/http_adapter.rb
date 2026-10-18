require_relative "internal/envelope"

module SimpleInference
  # Base class for HTTP adapters.
  #
  # Concrete adapters must implement `#call` and may override `#call_stream`
  # for incremental streaming.
  class HTTPAdapter
    def call(_request)
      raise NotImplementedError, "#{self.class} must implement #call"
    end

    # Streaming-capable request helper.
    #
    # When the response is `text/event-stream` (and 2xx), it yields raw body chunks
    # as they arrive via the given block, and returns a response hash with `body: nil`.
    #
    # For non-streaming responses, it behaves like `#call` and returns the full body.
    def call_stream(request)
      return call(request) unless block_given?

      response = call(request)
      envelope = Internal::Envelope.from_h(response)
      return response unless envelope.sse?

      yield envelope.body.to_s
      { status: envelope.status, headers: response.fetch(:headers), body: nil }
    end
  end

  module HTTPAdapters
    autoload :Default, "simple_inference/http_adapters/default"
    autoload :HTTPX, "simple_inference/http_adapters/httpx"
    autoload :AsyncHTTP, "simple_inference/http_adapters/async_http"
  end
end
