require_relative "internal/envelope"

module SimpleInference
  # One HTTP response as the protocols consume it.
  #
  # - `status` is an Integer HTTP status code
  # - `headers` is a Hash with downcased String keys
  # - `body` is the wire's parsed JSON object, or nil (a streamed success, or
  #   a body that was not a JSON object — its text is always in `raw_body`)
  # - `raw_body` is the raw response body String
  Response = Data.define(:status, :headers, :body, :raw_body) do
    def initialize(status:, headers:, body:, raw_body:)
      super(status: Integer(status), headers: Internal::Envelope.downcase_headers(headers), body:, raw_body:)
    end

    def success? = (200..299).cover?(status)
  end
end
