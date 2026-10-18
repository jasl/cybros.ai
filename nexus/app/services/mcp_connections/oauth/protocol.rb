# Flow's error handlers reference Faraday even with a custom HTTP factory.
require "faraday"

module McpConnections
  module OAuth
    class Protocol
      def self.call(...) = new(...).call

      def initialize(connection:, operation_id:, callback_params: nil, timeout_seconds: McpConnection::OAuthData::OPERATION_SECONDS)
        @connection = connection
        @operation_id = operation_id
        @callback_params = callback_params
        @timeout_seconds = timeout_seconds
        @storage = Storage.new(connection: connection, operation_id: operation_id)
        @kind = @storage.data.operation.kind
      end

      def call
        release_connection
        @http_client = ::Mcp::OAuthHttpClient.new(timeout_seconds: @timeout_seconds)
        flow = MCP::Client::OAuth::Flow.new(provider: provider, http_client_factory: -> { @http_client })
        case @kind
        when "start"
          challenge = authorization_challenge
          flow.run!(server_url: @connection.endpoint_url,
            resource_metadata_url: challenge["resource_metadata"], scope: challenge["scope"])
        when "finish" then flow.finish!(server_url: @connection.endpoint_url, callback_params: @callback_params)
        when "refresh"
          flow.refresh!(server_url: @connection.endpoint_url,
            resource_metadata_url: authorization_challenge["resource_metadata"])
        else raise "unknown MCP OAuth operation"
        end
        TokenResponse.apply(@storage.data) unless @kind == "start"
        result = @connection.complete_oauth_operation(operation_id: @operation_id, data: @storage.data)
        Result.new(outcome: result.outcome, connection: @connection,
          authorization_url: result.success? ? flow.authorization_url&.to_s : nil,
          expires_at: result.success? ? @connection.oauth_data.pending_authorization&.expires_at : nil,
          bearer_token: result.success? ? @connection.current_bearer_token : nil)
      rescue MCP::Client::OAuth::Flow::AuthorizationError,
          MCP::Client::OAuth::Provider::InsecureRedirectURIError,
          MCP::Client::OAuth::Provider::UnregisteredRedirectURIError
        failed(reauthorization_required: spent_grant?)
      rescue ActiveRecord::RecordInvalid
        # Validation leaves the rejected staged envelope dirty in memory;
        # restore the persisted claim before locking it for failure cleanup.
        @connection.reload
        failed(reauthorization_required: spent_grant?)
      rescue ::Mcp::Error => error
        failed(reauthorization_required: spent_grant?(request_sent: error.request_sent),
          outcome: error.code == :mcp_timeout ? :authorization_timeout : :authorization_failed)
      ensure
        @http_client&.close
      end

      private

        def provider
          uri = @storage.data.redirect_uri
          MCP::Client::OAuth::Provider.new(storage: @storage, redirect_uri: uri,
            client_metadata: {
              "client_name" => "Nexus",
              "redirect_uris" => [uri],
              "grant_types" => %w[authorization_code refresh_token],
              "response_types" => ["code"],
              "token_endpoint_auth_method" => "none",
            },
            redirect_handler: ->(_url) { },
            pending_authorization_max_age: McpConnection::OAuthData::AUTHORIZATION_SECONDS)
        end

        def authorization_challenge
          response = @http_client.get(@connection.endpoint_url) do |request|
            request.headers["Accept"] = "application/json, text/event-stream"
          end
          return {} unless response.status == 401

          MCP::Client::OAuth::Discovery.parse_www_authenticate(response.headers["www-authenticate"])
        end

        def spent_grant?(request_sent: false)
          (@kind == "refresh" && (request_sent || @http_client&.request_sent)) ||
            (@kind == "finish" && @storage.data.pending_authorization.nil?)
        end

        def failed(reauthorization_required:, outcome: :authorization_failed)
          @connection.fail_oauth_operation(operation_id: @operation_id,
            reauthorization_required: reauthorization_required)
          Result.new(outcome: outcome, connection: @connection)
        end

        def release_connection
          return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

          ApplicationRecord.connection_handler.clear_active_connections!
        end
    end
  end
end
