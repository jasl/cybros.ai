module McpConnections
  module OAuth
    class Credential
      WAIT_SECONDS = 0.05

      def self.call(...) = new(...).call

      def initialize(connection:, timeout_seconds:)
        @connection = connection
        @timeout_seconds = [timeout_seconds, McpConnection::OAuthData::OPERATION_SECONDS].min
      end

      def call
        unless @connection.auth_type == "oauth"
          return Result.new(outcome: @connection.credential_configured? ? :saved : :missing_credential,
            connection: @connection, bearer_token: @connection.current_bearer_token)
        end

        deadline = monotonic_time + @timeout_seconds
        # Only a concurrent in-flight refresh is waited on. The monotonic
        # deadline bounds every reread and never extends the caller's Task.
        loop do
          result = @connection.prepare_oauth_credential
          case result.outcome
          when :saved
            return Result.new(outcome: :saved, connection: @connection, bearer_token: @connection.current_bearer_token)
          when :refresh_required
            return Protocol.call(connection: @connection, operation_id: @connection.oauth_data.operation.id,
              timeout_seconds: [deadline - monotonic_time, 0.001].max)
          when :authorization_pending
            unless @connection.oauth_data&.operation&.kind == "refresh"
              return Result.new(outcome: :authorization_pending, connection: @connection)
            end
          else
            return Result.new(outcome: result.outcome, connection: @connection)
          end
          remaining = deadline - monotonic_time
          return Result.new(outcome: :authorization_timeout, connection: @connection) unless remaining.positive?

          release_connection
          sleep([WAIT_SECONDS, remaining].min)
        end
      end

      private

        def release_connection
          return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

          ApplicationRecord.connection_handler.clear_active_connections!
        end

        def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
