module McpConnections
  module OAuth
    class Finish
      def self.call(connection:, callback_params:)
        result = connection.claim_oauth_callback(state: callback_params.fetch("state", nil).to_s)
        if result.success?
          Protocol.call(connection: connection, operation_id: connection.oauth_data.operation.id,
            callback_params: callback_params)
        else
          Result.new(outcome: result.outcome, connection: connection)
        end
      end
    end
  end
end
