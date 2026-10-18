module Rho
  module IngressTelegram
    NAME = "rho.ingress_telegram".freeze

    def self.register(api)
      if api.host.config.mode == "runner"
        raise Rho::ConfigurationError, "rho-ingress-telegram needs mode full or agent"
      end
      settings = Settings.bindings(api.configuration)
      connections = Settings.connections(api.configuration)
      api.describe_status do
        issues = []
        active = settings.values.select(&:enabled?)
        issues << "A Telegram Connection token is not configured" if connections.values.select(&:enabled?).none?(&:configured?)
        issues << "A Telegram Bot target is not configured" if active.empty?
        issues << "A Telegram Bot owner is not configured" if active.any? { |row| !row.owner_id }
        { ready: issues.empty?, issues: issues }
      end
      api.register_command("telegram", usage: "telegram status",
        description: "Show Telegram connection and delivery issues") do |cli, arguments, _options|
        unless arguments.empty? || arguments == ["status"]
          raise Rho::Error, "Use rho telegram status; bind the owner with rho setup and manage access in the bot's private chat."
        end
        core = cli.core
        response = core.get(core.require_daemon, "/telegram/connections")
        document = core.parse(response)
        cli.out.puts(JSON.pretty_generate(document))
        document
      end
      coordinator = Coordinator.new(host: api.host, settings: settings, connections: connections)
      api.register_route("GET", "/telegram") do |request, ctx|
        status(request, ctx, coordinator)
      end
      api.register_route("POST", "/telegram/configuration") do |request, ctx|
        configure(request, ctx, coordinator)
      end
      api.register_route("POST", "/telegram/access") do |request, ctx|
        change_access(request, coordinator, ctx)
      end
      api.register_route("GET", "/telegram/connections") { |_request, _ctx| [200, { "connections" => coordinator.connections }] }
      api.register_route("GET", "/telegram/connection") { |request, _ctx| connection_detail(request, coordinator) }
      api.register_route("POST", "/telegram/connection") { |request, ctx| configure_connection(request, ctx, coordinator) }
      api.register_webui_module(root: File.expand_path("../../../webui", __dir__))

      return unless api.host.serving_tools

      api.on(:conversation_binding) { |id| coordinator.binding(id) }
      api.on(:member_connection) { |connection| coordinator.connection_changed(connection) }
      api.on(:configuration_change) { |config| coordinator.configure(config) }
      api.background(NAME) { coordinator.start }
      api.on(:shutdown) { coordinator.close }
    end

    def self.status(request, ctx, coordinator)
      query = request ? Rho::ControlServer.query(request) : {}
      audience = "owner"
      agent_id = agent_selector(ctx, query["agent_public_id"]) { |row| audience = row.fetch(:audience) }
      return agent_id if agent_id in Rho::Daemon::Refusal

      [200, coordinator.status(agent_public_id: agent_id, audience: audience)]
    end

    def self.configure(request, ctx, coordinator)
      input = Rho::ControlServer.json_body(request)
      agent_id = agent_selector(ctx, input.delete("agent_public_id"))
      return agent_id if agent_id in Rho::Daemon::Refusal

      apply_configuration do
        prepared = Configuration.new(config: ctx.config).prepare(input, agent_public_id: agent_id)
        ctx.configure_plugin(NAME, operations: prepared.operations, enabled: ctx.config.plugin_enabled?(NAME))
        [200, { "saved" => true, "applied" => true, "restart_required" => false }]
      end
    end

    def self.connection_detail(request, coordinator)
      id = Rho::ControlServer.query(request)["connection_public_id"]
      return Rho::Daemon::Refusal.malformed("A Connection UUID is required") unless Settings::UUID.match?(id.to_s)

      [200, { "connection" => coordinator.connection_status(id) }]
    rescue KeyError
      Rho::Daemon::Refusal.new(status: 404, code: "telegram_connection_unavailable", message: "Telegram Connection not found")
    end

    def self.configure_connection(request, ctx, coordinator)
      input = Rho::ControlServer.json_body(request)
      id = input.delete("connection_public_id")
      apply_configuration do
        prepared = Configuration.new(config: ctx.config).prepare_connection(input,
          connection_public_id: id, bot_id: coordinator.bot_id(connection_public_id: id))
        ctx.configure_plugin(NAME, operations: prepared.operations, enabled: ctx.config.plugin_enabled?(NAME), before_save: -> {
          coordinator.admit_connection(connection_public_id: prepared.connection_public_id, token: prepared.token, bot: prepared.bot)
        })
        # Saving can replace this registration and its coordinator. The receipt
        # describes the saved Connection; a subsequent GET reads the active worker.
        saved = Settings.connections(ctx.config.plugin_configuration(NAME)).fetch(prepared.connection_public_id)
        connection = saved.to_h.merge("public_id" => prepared.connection_public_id,
          "token" => { "present" => saved.configured? }, "bot" => prepared.bot,
          "connection" => saved.enabled? ? (saved.configured? ? "starting" : "configuration_error") : "disabled",
          "offset" => nil, "bot_count" => Settings.bindings(ctx.config.plugin_configuration(NAME)).count { |_id, row| row.connection_public_id == prepared.connection_public_id })
        [200, { "connection" => connection,
          "saved" => true, "applied" => true, "restart_required" => false }]
      end
    end

    def self.apply_configuration
      yield
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

    # The Agents projection marks exactly the editable, own named Agents
    # with their home setting. Reuse that authority rather than re-deriving
    # extension ownership or sibling lineage in the channel.
    def self.agent_selector(ctx, value)
      id = String.try_convert(value).to_s.downcase
      unless Settings::UUID.match?(id)
        return Rho::Daemon::Refusal.malformed(Locales::ENGLISH.fetch("agent_uuid_required"))
      end
      listing = ctx.list_named_agents
      return listing if listing in Rho::Daemon::Refusal

      row = listing.fetch(:bots).find { |candidate| candidate.fetch(:public_id) == id && candidate.key?(:home_workspace_public_id) }
      return Rho::Daemon::Refusal.new(status: 404, code: "bot_unavailable", message: Locales::ENGLISH.fetch("bot_unavailable")) unless row

      yield(row) if block_given?
      id
    end

    def self.change_access(request, coordinator, ctx)
      body = Rho::ControlServer.json_body(request)
      unless (body.keys - %w[list action id agent_public_id]).empty?
        return Rho::Daemon::Refusal.malformed("Telegram access accepts list, action, id and agent_public_id")
      end
      audience = "owner"
      agent_id = agent_selector(ctx, body.delete("agent_public_id")) { |row| audience = row.fetch(:audience) }
      return agent_id if agent_id in Rho::Daemon::Refusal
      if agent_id && audience != "external"
        return Rho::Daemon::Refusal.new(status: 422, code: "bot_owner_only", message: Locales::ENGLISH.fetch("owner_only"))
      end

      coordinator.change_access(agent_public_id: agent_id, list: body.fetch("list"), action: body.fetch("action"), id: body.fetch("id"))
      [200, coordinator.status(agent_public_id: agent_id, audience: audience)]
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
