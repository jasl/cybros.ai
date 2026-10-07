require "rho/ingress-telegram"
require "cybros_control"

module Rho
  module IngressTelegram
    # Configure the existing channel without consuming updates or changing its
    # durable routing/offset. The running daemon is the only polling owner.
    class Setup
      def initialize(home:, prompt:, env: ENV, clients: nil)
        @home, @prompt, @env = home, prompt, env
        @clients = clients || ->(token) { Client.new(token: token) }
      end

      def run(finish: false)
        config = Rho::Config.load(@home.settings_path, home: @home)
        values = config.plugin_configuration(NAME)
        settings = Settings.new(values, env: @env)
        @core = Rho::Core.new(home: @home)
        if finish
          return true unless config.plugin_enabled?(NAME) && settings.enabled? && !settings.owner_id

          raise Rho::Error, "Telegram access setup needs an interactive terminal." unless @prompt.interactive?
        end
        @home.prepare
        env_name = values.fetch("token_env", "RHO_TELEGRAM_BOT_TOKEN")
        environment_token = @env.fetch(env_name, "").strip
        token = finish ? settings.token : choose_token(settings.token, environment_token, env_name)
        input = { "enabled" => true }
        input["token"] = token if token != settings.token || settings.token_source == "none"
        prepared = Configuration.new(config: config, env: @env, clients: @clients).prepare(
          input, bot_id: configured_bot, verify: true)
        bot = prepared.bot

        @prompt.say("Telegram bot: @#{bot.fetch("username")}")
        @prompt.say("Open this bot in Telegram and send /start to see your numeric user ID.")
        if finish
          @prompt.say("With rho running, send /start to this bot, then enter your numeric ID below.")
        else
          @prompt.say("If the bot is not running yet, leave the ID blank. Start rho, send /start, then run rho setup telegram --finish.")
        end
        owner_id = ask_owner(settings.owner_id)
        if finish && !owner_id
          raise Rho::Error, "No bot owner was configured. Run rho setup telegram --finish again after sending /start to the bot."
        end
        operations = [*prepared.operations, { "op" => "set", "path" => ["owner_id"], "value" => owner_id }]
        @prompt.say("Bot owner: #{owner_id || "not configured; only private /start guidance is available"}")
        @prompt.say("The owner manages users and groups with /access and /ignore in a private chat with the bot.")
        raise CybrosControl::Cancelled unless @prompt.confirm("Save Telegram configuration?", default: true)

        result = @core.configure_extension(NAME, operations: operations, enabled: true)
        @prompt.say("Telegram is waiting for a bot owner; no agent messages are accepted yet.") unless owner_id
        @prompt.say(result["applied"] ? "Telegram configuration saved and applied to the running daemon; no message was sent by setup." :
          "Telegram configuration saved. It will load the next time rho starts; no message was sent by setup.")
        @prompt.say("Check `rho telegram status`, then send /status and a message to your bot once the owner ID is configured.")
        true
      rescue Client::Refused, Client::Unavailable => error
        raise Rho::Error, error.message
      end

      private

        def configured_bot
          daemon = @core.running_daemon
          if daemon
            response = @core.get(daemon, "/telegram")
            # Before the extension is loaded, this optional route is either
            # absent or the WebUI's HTML fallback. Malformed JSON still fails.
            absent = response.code.to_i == 404 || (response.code.to_i == 200 && response.content_type == "text/html")
            unless absent
              status = @core.parse(response)
              return status["bot_id"]
            end
          end

          nil
        end

        def choose_token(current, environment_token, env_name)
          if !current.empty? && current == environment_token
            @prompt.say("Using #{env_name} from the environment unless you replace it with a saved token.")
          end
          if !current.empty? && @prompt.confirm("Keep the current Telegram bot token?", default: true)
            current
          else
            @prompt.say("Create a bot with @BotFather, then paste its token below. It will not be displayed.")
            token = @prompt.ask("Bot token", secret: true).strip
            raise Rho::Error, "A Telegram bot token is required." if token.empty?

            token
          end
        end

        def ask_owner(current)
          loop do
            answer = @prompt.ask("Bot owner numeric user ID (blank keeps the current owner)", default: current.to_s)
            return nil if answer.empty?

            begin
              id = Integer(answer, 10)
              return id.to_s if id.positive?
            rescue ArgumentError
              # The prompt is the boundary for the operator's input.
            end
            @prompt.say("Use one positive numeric Telegram user ID, not a username.")
          end
        end
    end
  end
end
