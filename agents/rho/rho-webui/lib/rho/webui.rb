require_relative "webui/version"

module Rho
  # The browser surface registers its files with the daemon's existing server.
  module Webui
    NAME = "rho.webui".freeze

    def self.register(api)
      api.register_webui(root: File.expand_path("../../webui", __dir__))
      # Browser ICE credentials belong to this endpoint's configuration, not
      # the Runner's. Only admitted clients receive them, never static assets.
      api.register_route("GET", "/realtime/ice_servers") do |_request, _ctx|
        Protocol::HTTP::Response[200,
          { "content-type" => "application/json", "cache-control" => "no-store", "x-content-type-options" => "nosniff" },
          [JSON.generate(ice_servers: api.configuration.fetch("ice_servers", []))]]
      end
    end
  end
end
