module McpConnections
  module OAuth
    Result = Data.define(:outcome, :connection, :authorization_url, :expires_at, :bearer_token) do
      def initialize(outcome:, connection:, authorization_url: nil, expires_at: nil, bearer_token: nil)
        super
      end

      def success? = outcome == :saved
    end
  end
end
