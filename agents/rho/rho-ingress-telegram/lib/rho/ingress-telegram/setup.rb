require "rho/ingress-telegram"
require "cybros_control"

module Rho
  module IngressTelegram
    # Setup verifies transport credentials, then binds an existing Bot to one
    # explicit target. Only the daemon consumes updates or sends messages.
    class Setup
      def initialize(home:, prompt:, clients: nil, core: nil)
        @home, @prompt = home, prompt
        @clients = clients || ->(token) { Client.new(token: token) }
        @core = core || Rho::Core.new(home: home)
      end

      def run(finish: false)
        raise Rho::Error, "Telegram setup needs an interactive terminal." unless @prompt.interactive?
        if finish && !@core.running_daemon
          raise Rho::Error, "Start rho and create a Bot with a Home Workspace before binding its Telegram target."
        end

        @home.prepare
        config = Rho::Config.load(@home.settings_path, home: @home)
        connection_id = finish ? select_connection(config, create: false) : configure_connection(config)
        unless @core.running_daemon
          @prompt.say("Connection saved. Start rho, create a Bot with a Home Workspace, then use Bots or `rho setup telegram --finish` to bind its Telegram target.")
          return true
        end
        bind_bot(connection_id)
        true
      rescue Client::Refused, Client::Unavailable => error
        raise Rho::Error, error.message
      end

      private

        def select_connection(config, create:)
          rows = Settings.connections(config.plugin_configuration(NAME))
          rows = rows.select { |_id, row| row.enabled? && row.configured? } unless create
          if !create && rows.empty?
            raise Rho::Error, "Create a Telegram Connection with `rho setup telegram` first."
          end
          return nil if rows.empty?

          ids = rows.keys
          choices = rows.map { |id, row| "#{row.name} (#{id})" }
          choices << "Create a new Connection" if create
          index = choices.one? ? 0 : @prompt.choose("Telegram Connection", choices: choices)
          ids[index]
        end

        def configure_connection(config)
          id = select_connection(config, create: true)
          current = id ? Settings.connections(config.plugin_configuration(NAME)).fetch(id) : ConnectionSettings.new({})
          name = @prompt.ask("Connection name", default: current.name)
          token = choose_token(current.token)
          changes = { "name" => name, "enabled" => true, "token" => token }
          prepared = Configuration.new(config: config, clients: @clients).prepare_connection(changes,
            connection_public_id: id, bot_id: configured_bot(id, config), verify: true)
          @prompt.say("Telegram account: @#{prepared.bot.fetch("username")}")
          raise CybrosControl::Cancelled unless @prompt.confirm("Save this Telegram Connection?", default: true)

          if @core.running_daemon
            # The management route also checks other live Connections' physical
            # identities. Enable its empty management surface first if needed.
            @core.configure_extension(NAME, operations: [], enabled: true) unless config.plugin_enabled?(NAME)
            result = @core.configure_telegram_connection(changes, connection_public_id: id)
            id = result.fetch("connection").fetch("public_id")
          else
            @core.configure_extension(NAME, operations: prepared.operations, enabled: true)
            id = prepared.connection_public_id
          end
          @prompt.say("Connection saved; setup did not poll updates or send a message.")
          id
        end

        def configured_bot(id, config)
          return unless id && config.plugin_enabled?(NAME) && @core.running_daemon

          @core.telegram_connection(connection_public_id: id).dig("connection", "bot", "id")&.to_s
        end

        def bind_bot(connection_id)
          response = @core.get(@core.require_daemon, "/agents")
          document = @core.parse(response)
          raise Rho::Error, @core.failure_message(document) unless response.code.to_i == 200

          bots = document.fetch("bots").select { |row| row.key?("home_workspace_public_id") }
          if bots.empty?
            @prompt.say("Create a Bot and choose its Home Workspace in Bots, then bind this Connection and its Telegram target there or run `rho setup telegram --finish`.")
            return
          end
          index = bots.one? ? 0 : @prompt.choose("Bot", choices: bots.map { |row| "#{row["display_name"] || row.fetch("name")} (#{row.fetch("public_id")})" })
          bot = bots.fetch(index)
          if bot["home_workspace_public_id"].to_s.empty?
            raise Rho::Error, "Choose a Home Workspace for #{bot.fetch("name")} in Bots, then run `rho setup telegram --finish`."
          end
          id = bot.fetch("public_id")
          current = @core.telegram_settings(agent_public_id: id).fetch("configuration")
          @prompt.say("Bot: #{bot.fetch("name")} (#{id}); Home Workspace: #{bot.fetch("home_workspace_public_id")}")
          @prompt.say("Use one private chat ID or one group chat ID, with an optional forum topic. This Bot will accept only that target.")
          chat_id = ask_integer("Telegram chat ID", default: current.dig("target", "chat_id"), positive: false)
          topic_id = if chat_id.to_i.negative?
            ask_integer("Forum topic ID (blank for the whole chat)", optional: true)
          end
          owner_id = ask_integer("Bot owner numeric Telegram user ID", default: current["owner_id"])
          changes = { "enabled" => true, "connection_public_id" => connection_id,
            "target" => { "chat_id" => chat_id, "topic_id" => topic_id&.to_i }, "owner_id" => owner_id }
          @prompt.say("Target: #{chat_id}#{topic_id ? " / topic #{topic_id}" : ""}; owner: #{owner_id}")
          raise CybrosControl::Cancelled unless @prompt.confirm("Save this Bot target?", default: true)

          @core.configure_telegram(changes, agent_public_id: id)
          @prompt.say("Bot target saved. Open that target in Telegram and send /start, then /status and a message. Setup sent no message.")
        end

        def choose_token(current)
          return current if !current.empty? && @prompt.confirm("Keep the current Telegram bot token?", default: true)

          @prompt.say("Create a bot with @BotFather, then paste its token below. It will not be displayed.")
          token = @prompt.ask("Bot token", secret: true).strip
          raise Rho::Error, "A Telegram bot token is required." if token.empty?

          token
        end

        def ask_integer(label, default: nil, positive: true, optional: false)
          loop do
            text = @prompt.ask(label, default: default&.to_s)
            return nil if optional && text.empty?

            value = Integer(text, 10, exception: false)
            return value.to_s if value && (positive ? value.positive? : !value.zero?)

            @prompt.say(positive ? "Use one positive numeric Telegram ID." : "Use a nonzero numeric Telegram chat ID.")
          end
        end
    end
  end
end
