module Sso
  class Http
    MAX_BYTES = 1.megabyte

    # All destinations come from administrator-owned configuration or pinned
    # discovery origins. Private enterprise endpoints are valid. The HTTPX
    # session has no redirect or retry plugin, including for authorization codes.
    def self.json(verb, uri, headers: {}, form: nil)
      session = HTTPX.plugin(:stream).plugin(Mcp::HttpTransport::FixedOrigin)
        .plugin(Nexus::HttpDeadline).with(persistent: false, debug: nil, debug_redact: true)
      options = { headers: { "accept" => "application/json" }.merge(headers), stream: true,
        timeout: { connect_timeout: 4, request_timeout: 10, read_timeout: 10,
          write_timeout: 10, operation_timeout: 10 } }
      options[:form] = form if form
      response = session.request(verb, uri, **options)
      data = +""
      response.each do |chunk|
        raise ProtocolError if chunk.bytesize + data.bytesize > MAX_BYTES
        data << chunk
      end
      raise ProtocolError unless response.request.response.status.between?(200, 299)
      data.force_encoding(Encoding::UTF_8)
      raise ProtocolError unless data.valid_encoding?

      Hash.try_convert(JSON.parse(data)) || raise(ProtocolError)
    rescue JSON::ParserError, HTTPX::Error, SystemCallError, IOError, URI::Error, EncodingError
      raise ProtocolError, cause: nil
    ensure
      session&.close
    end
  end
end
