require_relative "../../support/nexus_server"

module E2E
  # Product journeys reserve rho's browser callback before starting Nexus.
  class ProductWorld < NexusServer
    attr_reader :rho_browser_url

    def initialize(**options)
      @browser_port = TCPServer.new(LOOPBACK, 0)
      @rho_browser_url = "http://#{LOOPBACK}:#{@browser_port.addr[1]}"
      super(**options, callback_urls: ["#{@rho_browser_url}/auth/callback"])
    end

    def start(**options)
      @browser_port.close
      super
    end

    def stop(**options)
      @browser_port.close unless @browser_port.closed?
      super
    end
  end
end
