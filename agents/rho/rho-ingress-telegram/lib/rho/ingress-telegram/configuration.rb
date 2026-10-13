module Rho
  module IngressTelegram
    # Credential verification runs before entering Core's settings writer.
    class Configuration
      Prepared = Data.define(:operations, :enabled, :token, :bot, :agent_public_id, :connection_public_id)

      def initialize(config:, clients: nil)
        @config = config
        @clients = clients || ->(token) { Client.new(token: token) }
      end

      def prepare(input, agent_public_id:)
        raise Rho::ConfigurationError, "telegram: an Agent UUID is required" unless Settings::UUID.match?(agent_public_id.to_s)

        input = input.to_h.transform_keys(&:to_s)
        unknown = input.keys - Settings::KEYS
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        document = @config.plugin_configuration(NAME)
        configurations = document.fetch("bots", {})
        settings = Settings.new(configurations.fetch(agent_public_id, {}).merge(input))
        Settings.bindings(document.merge("bots" => configurations.merge(agent_public_id => settings.to_h)))
        operations = input.keys.map do |key|
          { "op" => "set", "path" => ["bots", agent_public_id, key], "value" => settings.to_h.fetch(key) }
        end
        Prepared.new(operations: operations, enabled: settings.enabled?, token: nil, bot: nil,
          agent_public_id: agent_public_id, connection_public_id: settings.connection_public_id)
      end

      def prepare_connection(input, connection_public_id: nil, bot_id: nil, verify: false)
        input = input.to_h.transform_keys(&:to_s)
        unknown = input.keys - ConnectionSettings::KEYS
        raise Rho::ConfigurationError, "telegram: unknown Connection setting #{unknown.first}" unless unknown.empty?

        if connection_public_id && !Settings::UUID.match?(connection_public_id)
          raise Rho::ConfigurationError, "telegram: connection_public_id must be a Connection UUID"
        end
        configurations = @config.plugin_configuration(NAME).fetch("connections", {})
        if connection_public_id && !configurations.key?(connection_public_id)
          raise Rho::ConfigurationError, "telegram: the selected Connection does not exist"
        end
        current = connection_public_id ? configurations.fetch(connection_public_id) : {}
        if input.key?("token") && input["token"] && input["token"].to_s.strip.empty?
          raise Rho::ConfigurationError, "telegram: token must be nonempty; use null to clear the saved token"
        end
        settings = ConnectionSettings.new(current.merge(input))
        connection_public_id ||= SecureRandom.uuid_v7
        Settings.connections("connections" => configurations.merge(connection_public_id => current.merge(input)))
        previous = ConnectionSettings.new(current)
        verify ||= input.key?("token") || (settings.enabled? && !previous.enabled?)
        bot = identify(settings.token, bot_id: bot_id) if verify && settings.configured?
        values = settings.to_h.merge("token" => (settings.token unless settings.token.empty?))
        fields = configurations.key?(connection_public_id) ? input.keys : values.keys
        operations = fields.map do |key|
          { "op" => "set", "path" => ["connections", connection_public_id, key], "value" => values.fetch(key) }
        end
        Prepared.new(operations: operations, enabled: settings.enabled?, token: settings.token, bot: bot,
          agent_public_id: nil, connection_public_id: connection_public_id)
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
          raise Rho::ConfigurationError, "telegram: this Connection is bound to another physical bot; create a new Connection"
        end
        bot.slice("id", "username")
      end
    end
  end
end
