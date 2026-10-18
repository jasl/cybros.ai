module McpConnections
  module OAuth
    # Protocol writes are staged until the complete response can be installed.
    # Pending-state consumption is the exception: commit it before spending the
    # code so a crashed callback can never redeem that grant again.
    class Storage
      attr_reader :data

      def initialize(connection:, operation_id:)
        @connection = connection
        @operation_id = operation_id
        @data = McpConnection::OAuthData.new(connection.oauth_data.as_json)
      end

      def tokens = data.tokens
      def save_tokens(tokens) = data.tokens = tokens
      def client_information = data.client_information
      def save_client_information(information) = data.client_information = information

      def save_pending_authorization(state, envelope)
        data.pending_authorization = McpConnection::OAuthData::PendingAuthorization.new(
          state: state, envelope: envelope,
          expires_at: Time.at(envelope.fetch("created_at")) + McpConnection::OAuthData::AUTHORIZATION_SECONDS,
          owner_authority_generation: data.operation.owner_authority_generation
        )
      end

      def pending_authorization(state)
        pending = data.pending_authorization
        if pending && ActiveSupport::SecurityUtils.secure_compare(pending.state, state)
          pending.envelope
        end
      end

      def delete_pending_authorization(state)
        consumed = @connection.consume_oauth_pending(operation_id: @operation_id, state: state)
        data.pending_authorization = nil if consumed
        consumed
      ensure
        unless ApplicationRecord.connection_pool.active_connection?&.transaction_open?
          ApplicationRecord.connection_handler.clear_active_connections!
        end
      end
    end
  end
end
