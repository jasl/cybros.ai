# Loaded by the E2E launcher before the ordinary Nexus entry point. Its Rails
# hook runs after autoloading is ready, including in the separate queue host.
require_relative "../../../nexus/config/boot"
require "rails"

module E2E
  module McpFixtureTransport
    def initialize(endpoint_url:, **)
      super
      if [ENV.fetch("E2E_MCP_FIXTURE_URL"), ENV.fetch("E2E_MCP_OAUTH_FIXTURE_URL")].include?(endpoint_url)
        @session = @session.with(safe_private_ranges: ["127.0.0.1/32"])
      end
    end
  end

  module McpFixtureOAuthTransport
    private

      def exchange(verb, url, &block)
        previous = @session
        fixture = URI.parse(ENV.fetch("E2E_MCP_OAUTH_FIXTURE_URL"))
        destination = URI.parse(url)
        # Only this world's OAuth peer may use a loopback exception. Restore
        # the ordinary session before the next discovered destination.
        if [destination.scheme, destination.host, destination.port] == [fixture.scheme, fixture.host, fixture.port]
          @session = @session.with(safe_private_ranges: ["127.0.0.1/32"])
        end
        super
      ensure
        @session.close unless @session.equal?(previous)
        @session = previous
      end
  end

  class McpFixtureRailtie < Rails::Railtie
    config.to_prepare do
      Mcp::HttpTransport.prepend(McpFixtureTransport)
      Mcp::OAuthHttpClient.prepend(McpFixtureOAuthTransport)
    end
  end
end
