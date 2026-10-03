require_relative "setup/installation"

module Rho
  module Extensions
    # Setup is available before any optional channel has been enabled.
    module Setup
      NAME = "rho.setup".freeze

      def self.register(api)
        api.register_route("GET", "/installation") { |_request, ctx| Installation.read(ctx) }
        api.register_command("setup", usage: "setup [SECTION]",
          description: "Configure Nexus, a default model and optional Telegram messaging",
          options: { "public-url": { type: :string, desc: "Browser-reachable Nexus URL (API requests keep --nexus-url)" },
            finish: { type: :boolean, default: false, desc: "Finish Telegram access after starting the configured bot" } }) do |cli, arguments, options|
          require_relative "../cli/setup"
          raise Rho::Error, "Use rho setup [model|telegram]." if arguments.length > 1

          Rho::Cli::Setup.new(cli: cli, nexus_url: options[:"nexus-url"], public_url: options[:"public-url"]).run(arguments.first, finish: options[:finish])
        end
      end
    end
  end
end
