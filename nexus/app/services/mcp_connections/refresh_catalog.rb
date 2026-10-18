module McpConnections
  # Explicit discovery publishes the complete local catalog once. Reads and tool
  # assembly never contact the service; a concurrent configuration edit wins.
  class RefreshCatalog
    TIMEOUT_SECONDS = 20

    def self.call(...) = new(...).call

    def initialize(connection:, expected_lock_version:)
      @connection = connection
      @expected_lock_version = expected_lock_version
    end

    def call
      deadline = monotonic_time + TIMEOUT_SECONDS
      return result(:stale_object) if @connection.lock_version != @expected_lock_version
      return result(:not_authorized) unless @connection.owner.active?

      credential = OAuth::Credential.call(connection: @connection, timeout_seconds: deadline - monotonic_time)
      return result(credential.outcome) unless credential.success?

      endpoint_url = @connection.endpoint_url
      @bearer_token = credential.bearer_token
      remaining = deadline - monotonic_time
      return result(:discovery_failed) unless remaining.positive?

      release_connection
      catalog = Mcp::Client.open(endpoint_url: endpoint_url, bearer_token: @bearer_token,
        timeout_seconds: remaining) { |client| client.list_tools }
      @connection.revise(attributes: { catalog: catalog, catalog_refreshed_at: Time.current },
        expected_lock_version: @expected_lock_version)
    rescue Mcp::Error => error
      @connection.reject_oauth_credential(bearer_token: @bearer_token) if error.code == :mcp_authentication_failed
      result(:discovery_failed)
    end

    private

      def release_connection
        return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

        ApplicationRecord.connection_handler.clear_active_connections!
      end

      def result(outcome) = McpConnection::Result.new(outcome: outcome, connection: @connection)

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
