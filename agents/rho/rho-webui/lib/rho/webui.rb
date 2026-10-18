require_relative "webui/version"

module Rho
  # The browser surface registers its files with the daemon's existing server.
  module Webui
    NAME = "rho.webui".freeze

    def self.register(api)
      api.register_webui(root: File.expand_path("../../webui", __dir__))
    end
  end
end
