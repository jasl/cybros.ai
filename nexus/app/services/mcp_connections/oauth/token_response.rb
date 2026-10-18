module McpConnections
  module OAuth
    # Flow parses the object and preserves an omitted refresh token. This is
    # the installation boundary for the fields Nexus uses to authorize HTTP.
    module TokenResponse
      module_function

      def apply(data, now: Time.current)
        tokens = data.tokens
        access = tokens.fetch("access_token", nil).to_s
        refresh = tokens["refresh_token"]&.to_s
        type = tokens.fetch("token_type", nil).to_s
        unless header_token?(access) && (refresh.nil? || header_token?(refresh)) && type.casecmp?("Bearer")
          raise ::Mcp::Error.new(:mcp_authentication_failed)
        end

        expiry = nil
        if tokens.key?("expires_in")
          seconds = Float(tokens.fetch("expires_in"), exception: false)
          unless seconds&.finite? && seconds.positive?
            raise ::Mcp::Error.new(:mcp_authentication_failed)
          end
          expiry = now + seconds
          raise ::Mcp::Error.new(:mcp_authentication_failed) unless expiry.year <= 9999
        end
        data.tokens = tokens.merge("access_token" => access, "token_type" => "Bearer")
        data.tokens["refresh_token"] = refresh if refresh
        data.expires_at = expiry
      rescue RangeError
        raise ::Mcp::Error.new(:mcp_authentication_failed), cause: nil
      end

      def header_token?(token)
        token.present? && token.bytesize <= McpConnection::TOKEN_MAX_LENGTH && !token.match?(/[\r\n\0]/)
      end
    end
  end
end
