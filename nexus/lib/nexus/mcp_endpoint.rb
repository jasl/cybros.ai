module Nexus
  module McpEndpoint
    MAX_BYTES = 8192
    class Invalid < ArgumentError; end

    def self.parse(value)
      text = value.to_s
      raise Invalid, "Invalid MCP endpoint" if text.bytesize > MAX_BYTES

      uri = URI.parse(text)
      unless %w[http https].include?(uri.scheme) && uri.host.present? &&
          uri.port.between?(1, 65_535) && uri.userinfo.nil? && uri.fragment.nil?
        raise Invalid, "Invalid MCP endpoint"
      end
      uri
    rescue URI::InvalidURIError, URI::InvalidComponentError
      raise Invalid, "Invalid MCP endpoint", cause: nil
    end
  end
end
