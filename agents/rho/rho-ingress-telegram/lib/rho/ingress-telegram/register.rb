module Rho
  module IngressTelegram
    NAME = "rho.ingress_telegram".freeze

    def self.register(api)
      if api.host.config.mode == "runner"
        raise Rho::ConfigurationError, "rho-ingress-telegram needs mode full or agent"
      end
      settings = Settings.new(api.host.config.telegram, home: api.host.home)
      api.register_command("telegram", usage: "telegram status",
        description: "Show Telegram connection and delivery issues") do |cli, arguments, _options|
        unless arguments.empty? || arguments == ["status"]
          raise Rho::Error, "Use rho telegram status; bind the owner with rho setup and manage access in the bot's private chat."
        end
        core = cli.core
        response = core.get(core.require_daemon, "/telegram")
        document = core.parse(response)
        cli.out.puts(JSON.pretty_generate(document))
        document
      end
      coordinator = nil
      api.register_route("GET", "/telegram") do |_request, _ctx|
        [200, coordinator ? coordinator.status : { "enabled" => false }]
      end
      return unless settings.enabled?

      GroupProfile.register(api)
      return unless api.host.serving_tools

      coordinator = Coordinator.new(host: api.host, settings: settings)
      api.on(:conversation_binding) { |id| coordinator.binding(id) }
      api.on(:member_connection) { |connection| coordinator.connection_changed(connection) }
      api.background(NAME) { coordinator.start }
      api.on(:shutdown) { coordinator.close }
    end
  end
end
