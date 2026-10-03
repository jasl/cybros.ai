module CybrosAgentTest
  # The scripted transport double for both API planes, implementing the
  # transport contract. Each call shifts one scripted step —
  # `[status, headers, body]` or `:connection_error` — and records everything
  # the client encoded, so a test can assert the wire request as data.
  class FakeTransport
    attr_reader :requests

    def initialize(script)
      @script = script
      @requests = []
    end

    def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {},
             timeout:, accept: CybrosAgent::JSON_MEDIA, sink: nil)
      @requests << {
        path: path, method: method, credential: credential,
        body: body, form: form, params: params, headers: headers, timeout: timeout, accept: accept,
        sink: sink,
      }
      step = @script.shift
      raise CybrosAgent::TransportError, "boom" if step == :connection_error

      status, headers, body = step
      # A streamed success lands in the sink and carries no body back — the
      # real transport's shape; a refusal is read whole.
      if sink && (200..299).cover?(status)
        sink.write(body.to_s)
        return CybrosAgent::Response.new(status: status, headers: headers || {}, body: nil)
      end

      CybrosAgent::Response.new(status: status, headers: headers || {}, body: body)
    end
  end
end
