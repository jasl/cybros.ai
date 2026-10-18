require_relative "../support/mcp_test_server"

module McpOAuthTestHelper
  private

    def with_oauth_server(token_response: nil, metadata_response: nil, challenge: false)
      token_response ||= ->(_form) {
        { json: { access_token: "synthetic-access", refresh_token: "synthetic-refresh", token_type: "Bearer", expires_in: 3600 } }
      }
      server = McpTestServer.new do |request|
        path = request.fetch(:line).split.fetch(1)
        origin = server.endpoint_url.delete_suffix("/mcp")
        case path
        when "/mcp"
          if challenge
            { status: 401, headers: { "WWW-Authenticate" => %(Bearer resource_metadata="#{origin}/authorization-resource", scope="challenge:read") } }
          else
            { status: 405, json: {} }
          end
        when "/authorization-resource"
          { json: { resource: server.endpoint_url, authorization_servers: [origin], scopes_supported: ["metadata:read"] } }
        when "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"
          challenge ? { status: 404, json: {} } : { json: { resource: server.endpoint_url, authorization_servers: [origin] } }
        when "/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"
          metadata_response&.call || { json: { issuer: origin, authorization_endpoint: "#{origin}/authorize", token_endpoint: "#{origin}/token",
            registration_endpoint: "#{origin}/register", code_challenge_methods_supported: ["S256"],
            response_types_supported: ["code"], grant_types_supported: %w[authorization_code refresh_token],
            token_endpoint_auth_methods_supported: ["none"], authorization_response_iss_parameter_supported: true } }
        when "/register"
          { json: { client_id: "synthetic-client", token_endpoint_auth_method: "none",
            redirect_uris: request.fetch(:body).fetch("redirect_uris") } }
        when "/token"
          token_response.call(URI.decode_www_form(request.fetch(:body)).to_h)
        else
          { status: 404, json: {} }
        end
      end
      session = HTTPX.plugin(:ssrf_filter, safe_private_ranges: ["127.0.0.1/32"])
      HTTPX.stub(:plugin, session) { yield server }
    ensure
      server&.close
    end

    def create_oauth_connection(server, **attributes)
      users(:member).mcp_connections.create!(name: "OAuth test", auth_type: "oauth",
        endpoint_url: server.endpoint_url, **attributes)
    end

    def start_oauth(connection)
      McpConnections::OAuth::Start.call(connection: connection, expected_lock_version: connection.lock_version,
        redirect_uri: "https://nexus.example.test/oauth/callback")
    end

    def finish_oauth(connection, server, state: connection.reload.oauth_data.pending_authorization.state, **parameters)
      McpConnections::OAuth::Finish.call(connection: connection, callback_params: {
        "state" => state, "code" => "synthetic-code", "iss" => server.endpoint_url.delete_suffix("/mcp"),
      }.merge(parameters.stringify_keys))
    end

    def authorize_oauth(connection, server)
      assert_predicate start_oauth(connection), :success?
      assert_predicate finish_oauth(connection, server), :success?
    end

    def expire_oauth(connection)
      data = connection.reload.oauth_data
      data.expires_at = 1.minute.ago
      connection.update!(oauth_data: data)
    end

    def token_requests(server)
      server.requests.select { |request| request.fetch(:line).start_with?("POST /token ") }
    end
end
