module McpConnections
  module OAuth
    class Start
      def self.call(connection:, expected_lock_version:, redirect_uri:)
        result = connection.begin_oauth_authorization(expected_lock_version: expected_lock_version,
          redirect_uri: redirect_uri)
        if result.success?
          Protocol.call(connection: connection, operation_id: connection.oauth_data.operation.id)
        else
          Result.new(outcome: result.outcome, connection: connection)
        end
      end
    end
  end
end
