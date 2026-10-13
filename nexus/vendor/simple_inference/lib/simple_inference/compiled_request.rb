module SimpleInference
  # One in-process provider request after every deterministic request step has
  # completed. It is intentionally not serializable: callers only need the
  # exact wire payload and the protocol result assembler that will consume the
  # provider response.
  class CompiledRequest
    attr_reader :http_method, :path, :headers, :payload, :expect_json

    def initialize(http_method:, path:, headers:, payload:, stream:, expect_json:, &executor)
      @http_method = http_method
      @path = path
      @headers = headers
      @payload = payload
      @stream = stream
      @expect_json = expect_json
      @executor = executor
      freeze
    end

    def stream? = @stream

    def execute(config)
      @executor.call(config, self)
    end
  end
end
