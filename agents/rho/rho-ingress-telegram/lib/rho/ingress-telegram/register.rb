module Rho
  module IngressTelegram
    NAME = "rho.ingress_telegram".freeze

    def self.register(api)
      if api.host.config.mode == "runner"
        raise Rho::ConfigurationError, "rho-ingress-telegram needs mode full or agent"
      end
      settings = Settings.new(api.configuration)
      api.describe_status do
        issues = []
        issues << "A Telegram bot token is not configured" unless settings.enabled?
        issues << "A Telegram bot owner is not configured" unless settings.owner_id
        { ready: issues.empty?, issues: issues }
      end
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
      coordinator = Coordinator.new(host: api.host, settings: settings)
      api.register_route("GET", "/telegram") do |_request, _ctx|
        [200, coordinator.status]
      end
      api.register_route("POST", "/telegram/configuration") do |request, ctx|
        configure(request, ctx, coordinator)
      end
      api.register_route("POST", "/telegram/access") do |request, _ctx|
        change_access(request, coordinator)
      end

      GroupProfile.register(api) if settings.enabled?
      return unless api.host.serving_tools

      api.on(:conversation_binding) { |id| coordinator.binding(id) }
      api.on(:member_connection) { |connection| coordinator.connection_changed(connection) }
      api.on(:configuration_change) { |config| coordinator.configure(config) }
      api.background(NAME) { coordinator.start }
      api.on(:shutdown) { coordinator.close }
    end

    def self.configure(request, ctx, coordinator)
      prepared = Configuration.new(config: ctx.config).prepare(
        Rho::ControlServer.json_body(request), bot_id: coordinator.bot_id)
      ctx.configure_plugin(NAME, operations: prepared.operations, enabled: prepared.enabled)
      coordinator.remember_bot(prepared.token, prepared.bot)
      [200, { "saved" => true, "applied" => true, "restart_required" => false }]
    rescue Rho::Settings::ApplyError => error
      Rho::Daemon::Refusal.new(status: 503, code: "settings_apply_failed", message: error.message, extra: { saved: true })
    rescue Rho::ConfigurationError => error
      Rho::Daemon::Refusal.malformed(error.message)
    rescue Client::Refused
      Rho::Daemon::Refusal.new(status: 422, code: "telegram_token_refused", message: "Telegram refused the bot token; configuration was not saved")
    rescue Client::Unavailable
      Rho::Daemon::Refusal.new(status: 502, code: "telegram_unavailable", message: "Telegram could not verify the bot token; configuration was not saved")
    rescue Rho::ConnectionError
      Rho::Daemon::Refusal.new(status: 409, code: "telegram_unavailable", message: "Telegram configuration could not be applied; check the current status")
    end

    def self.change_access(request, coordinator)
      body = Rho::ControlServer.json_body(request)
      unless (body.keys - %w[list action id]).empty?
        return Rho::Daemon::Refusal.malformed("Telegram access accepts list, action and id")
      end
      coordinator.change_access(list: body.fetch("list"), action: body.fetch("action"), id: body.fetch("id"))
      [200, coordinator.status]
    rescue Rho::ConfigurationError => error
      Rho::Daemon::Refusal.malformed(error.message)
    rescue Rho::ConnectionError
      Rho::Daemon::Refusal.new(status: 409, code: "telegram_profile_unavailable", message: "Telegram access needs a connected Agent profile")
    rescue CybrosAgent::TransportError
      Rho::Daemon::Refusal.new(status: 502, code: "telegram_profile_unavailable", message: "Telegram access could not reach the Agent profile")
    rescue CybrosAgent::Api::Error => error
      Rho::Daemon::Refusal.from_api_error(error)
    end
  end
end
