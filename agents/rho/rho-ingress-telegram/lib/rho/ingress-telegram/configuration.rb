module Rho
  module IngressTelegram
    # Validate the entire channel change before writing either settings or the
    # credential. Telegram verification happens outside the daemon settings lock.
    class Configuration
      EXTENSION = "rho/ingress-telegram".freeze
      Prepared = Data.define(:patch, :token_changed, :saved_token, :token, :bot) do
        def persist_token(home)
          return unless token_changed

          file = TokenFile.new(home)
          saved_token ? file.write(saved_token) : file.clear
        end
      end

      def initialize(home:, config:, env: ENV, clients: nil)
        @home, @config, @env = home, config, env
        @clients = clients || ->(token) { Client.new(token: token) }
      end

      def prepare(input, bot_id: nil, verify: false)
        input = input.to_h.transform_keys(&:to_s)
        unknown = input.keys - (Settings::KEYS + %w[enabled token])
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        enabled = input.fetch("enabled", @config.extensions.include?(EXTENSION))
        unless enabled == true || enabled == false
          raise Rho::ConfigurationError, "telegram: enabled must be true or false"
        end
        values = @config.telegram.merge(input.slice(*Settings::KEYS))
        saved = if input.key?("token")
          input["token"]&.to_s&.strip
        else
          TokenFile.new(@home).read
        end
        if input.key?("token") && saved == ""
          raise Rho::ConfigurationError, "telegram: token must be nonempty; use null to clear the saved token"
        end
        env_name = values.fetch("token_env", "RHO_TELEGRAM_BOT_TOKEN").to_s.strip
        token = saved.to_s.empty? ? @env.fetch(env_name, "").to_s.strip : saved
        settings = Settings.new(values, env: { env_name => token })
        raise Rho::ConfigurationError, "telegram: a bot token is required before enabling Telegram" if enabled && !settings.enabled?

        # Setting a credential always verifies it, including while disabled.
        # Ordinary owner/media edits need no outbound Telegram request.
        previous = Settings.new(@config.telegram, home: @home, env: @env)
        verify ||= input.key?("token") || token != previous.token || (enabled && !@config.extensions.include?(EXTENSION))
        bot = identify(token, bot_id: bot_id) if verify && !token.empty?
        extensions = @config.extensions - [EXTENSION]
        extensions << EXTENSION if enabled
        Prepared.new(patch: { "telegram" => settings.to_h, "extensions" => extensions },
          token_changed: input.key?("token"), saved_token: saved, token: token, bot: bot)
      end

      def identify(token, bot_id: nil)
        bot = Sync do
          client = @clients.call(token)
          begin
            client.call("getMe")
          ensure
            client.close
          end
        end
        if bot_id && bot_id.to_s != bot.fetch("id").to_s
          raise Rho::ConfigurationError, "telegram: this Agent profile is bound to another bot; use a different Agent"
        end
        bot.slice("id", "username")
      end
    end
  end
end
