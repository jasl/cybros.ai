module Rho
  class Daemon
    # The one owner of the transport, read at call time so a test swapping it
    # after boot is observed by every collaborator. `nil` stays nil: the SDK builds one HTTP transport per client.
    class Wire
      attr_accessor :api_transport

      def initialize(base_url:, api_transport: nil)
        @base_url = base_url
        @api_transport = api_transport
      end

      def client(credential = nil, credential_provider: nil)
        CybrosAgent::Client.new(base_url: @base_url, credential: credential,
          credential_provider: credential_provider, transport: @api_transport)
      end

      # The executor plane, on the transport credential: announcements,
      # inbox polling and task lifecycle operations.
      def executor_client(credential = nil, credential_provider: nil)
        CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: credential,
          credential_provider: credential_provider, transport: @api_transport)
      end
    end
  end
end
