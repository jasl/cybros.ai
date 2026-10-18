module CybrosAgent
  # The transport contract every plane and the device flow share:
  # call(path, method:, credential:, body:, form:, params:, headers:, timeout:, accept:)
  # answers a Response or raises TransportError. Loads without httpx so a
  # custom transport can be written without the default one installed.
  JSON_MEDIA = "application/json".freeze
  ANY_MEDIA = "*/*".freeze

  # No server response arrived (connection reset, timeout); the caller owns
  # the retry policy.
  class TransportError < Error; end

  # The transport can prove no request bytes were dispatched, so a
  # single-use refresh token may safely be presented again.
  class RequestNotSentError < TransportError; end

  # `body` is the parsed JSON for a JSON `accept` (nil when empty or not
  # JSON) and the raw bytes for any other media, so a generated image is never
  # parsed into a nil where a file should be.
  Response = Data.define(:status, :headers, :body) do
    include Redacted

    def inspect = redacted(status:, hidden: %i[headers body])

    # A missing or unparseable Retry-After is still throttling: one second.
    def retry_after = [header("Retry-After").to_i, 1].max

    # The validator an attachment read answered, nil when none came.
    def etag = header("ETag")

    # Receipt replay preserves the original status and body.
    def idempotency_replayed? = header("Idempotency-Replayed") == "true"

    private

      def header(name)
        headers.each { |field, value| return value if field.casecmp?(name) }
        nil
      end
  end
end
