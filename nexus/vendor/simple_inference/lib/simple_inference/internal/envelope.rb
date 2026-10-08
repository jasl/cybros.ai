module SimpleInference
  module Internal
    # The adapter envelope — the symbol-keyed {status:, headers:, body:} Hash
    # every HTTPAdapter returns — read STRICTLY once (`from_h`), so a
    # malformed adapter fails loudly at the seam instead of surfacing as a
    # silent status-0 HTTPError later. Header names downcase here, which is
    # what makes single-key lookups like headers["content-type"] unambiguous
    # everywhere else.
    Envelope = Data.define(:status, :headers, :body) do
      def self.from_h(raw) = new(status: raw.fetch(:status), headers: raw.fetch(:headers), body: raw.fetch(:body))

      def self.downcase_headers(headers) = (headers || {}).transform_keys { |name| name.to_s.downcase }

      # A non-numeric status raises ArgumentError/TypeError — never a silent 0.
      def initialize(status:, headers:, body:)
        super(status: Integer(status), headers: Envelope.downcase_headers(headers), body:)
      end

      def success? = (200..299).cover?(status)

      # Server-Sent-Events sniff over a SUCCESSFUL response's headers.
      def sse? = success? && headers.fetch("content-type", "").include?("text/event-stream")

      def event_stream? = success? && headers.fetch("content-type", "").include?("application/vnd.amazon.eventstream")

      # Both streaming encodings ride the same adapter deadlines, cancellation
      # and connection ownership. The protocol owns decoding their bytes.
      def streaming? = sse? || event_stream?
    end
  end
end
