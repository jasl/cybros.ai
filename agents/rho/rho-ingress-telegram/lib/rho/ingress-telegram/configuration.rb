module Rho
  module IngressTelegram
    # Validate the channel change before writing the plugin configuration.
    # Telegram verification happens outside the daemon settings lock.
    class Configuration
      Prepared = Data.define(:operations, :enabled, :token, :bot)

      def initialize(config:, env: ENV, clients: nil)
        @config, @env = config, env
        @clients = clients || ->(token) { Client.new(token: token) }
      end

      def prepare(input, bot_id: nil, verify: false)
        input = input.to_h.transform_keys(&:to_s)
        unknown = input.keys - (Settings::KEYS + ["enabled"])
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        enabled = input.fetch("enabled", @config.plugin_enabled?(NAME))
        unless enabled == true || enabled == false
          raise Rho::ConfigurationError, "telegram: enabled must be true or false"
        end
        values = @config.plugin_configuration(NAME).merge(input.slice(*Settings::KEYS))
        if input.key?("token") && input["token"] && input["token"].to_s.strip.empty?
          raise Rho::ConfigurationError, "telegram: token must be nonempty; use null to clear the saved token"
        end
        settings = Settings.new(values, env: @env)
        previous = Settings.new(@config.plugin_configuration(NAME), env: @env)
        # Credential verification happens before the core configuration write lock.
        verify ||= input.key?("token") || settings.token != previous.token || (enabled && !@config.plugin_enabled?(NAME))
        bot = identify(settings.token, bot_id: bot_id) if verify && settings.enabled?
        operations = input.slice(*Settings::KEYS).map do |key, value|
          value = settings.public_send(key) unless key == "token"
          value = value.to_s.strip if key == "token" && value
          { "op" => "set", "path" => [key], "value" => value }
        end
        Prepared.new(operations: operations, enabled: enabled, token: settings.token, bot: bot)
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
