module Rho
  module IngressTelegram
    # A Bot admits messages only from its configured Connection and exact target.
    class Settings
      KEYS = %w[enabled connection_public_id target owner_id stale_after input_debounce_seconds transcription_model speech_model].freeze
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze

      attr_reader :connection_public_id, :target, :owner_id, :stale_after, :input_debounce_seconds, :transcription_model, :speech_model

      def self.connections(document)
        rows = document.to_h.fetch("connections", {}).to_h.to_h do |key, value|
          raise Rho::ConfigurationError, "telegram: Connection keys must be UUIDs" unless UUID.match?(key)

          [key, ConnectionSettings.new(value)]
        end
        tokens = rows.values.select(&:configured?).map(&:token)
        raise Rho::ConfigurationError, "telegram: a token is already configured for another Connection" unless tokens.uniq.length == tokens.length

        rows
      end

      def self.bindings(document)
        connections = connections(document)
        targets = []
        document.to_h.fetch("bots", {}).to_h.to_h do |key, value|
          raise Rho::ConfigurationError, "telegram: Bot keys must be Agent UUIDs" unless UUID.match?(key)

          settings = new(value)
          if settings.connection_public_id && !connections.key?(settings.connection_public_id)
            raise Rho::ConfigurationError, "telegram: the selected Connection does not exist"
          end
          if settings.configured?
            target = [settings.connection_public_id, *settings.target.values_at("chat_id", "topic_id")]
            raise Rho::ConfigurationError, "telegram: this Connection target is already bound to another Bot" if targets.include?(target)

            targets << target
          end
          [key, settings]
        end
      end

      def initialize(document)
        document = document.to_h.transform_keys(&:to_s)
        unknown = document.keys - KEYS
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        @enabled = document.fetch("enabled", false)
        raise Rho::ConfigurationError, "telegram: enabled must be true or false" unless @enabled == true || @enabled == false

        @connection_public_id = document["connection_public_id"]&.to_s
        if @connection_public_id && !UUID.match?(@connection_public_id)
          raise Rho::ConfigurationError, "telegram: connection_public_id must be a Connection UUID"
        end
        @target = normalize_target(document["target"]) unless document["target"].nil?
        @owner_id = Integer(document.fetch("owner_id").to_s, 10).to_s unless document["owner_id"].nil?
        @stale_after = Integer(document.fetch("stale_after", 600).to_s, 10)
        @input_debounce_seconds = Integer(document.fetch("input_debounce_seconds", 2).to_s, 10)
        unless (0..10).cover?(@input_debounce_seconds)
          raise Rho::ConfigurationError, Locales::ENGLISH.fetch("input_debounce_invalid")
        end
        @transcription_model = document["transcription_model"].to_s.strip
        @speech_model = document["speech_model"].to_s.strip
        unless (!@owner_id || @owner_id.to_i.positive?) && @stale_after.positive?
          raise Rho::ConfigurationError, "telegram: owner_id and stale_after must be positive"
        end
        raise Rho::ConfigurationError, "telegram: an enabled Bot requires a Connection and target" if enabled? && !configured?
      rescue ArgumentError, TypeError
        raise Rho::ConfigurationError, Locales::ENGLISH.fetch("settings_integers_required")
      end

      def enabled? = @enabled
      def configured? = !@connection_public_id.nil? && !@target.nil?
      def owner?(user_id) = !@owner_id.nil? && @owner_id == user_id.to_s
      def matches?(update) = configured? && @target.fetch("chat_id") == update.chat_id && @target["topic_id"] == update.topic_id
      def to_h = (KEYS - %w[enabled]).to_h { |key| [key, public_send(key)] }.merge("enabled" => enabled?)

      private

        def normalize_target(value)
          value = value.to_h.transform_keys(&:to_s)
          unless (value.keys - %w[chat_id topic_id]).empty? && value.key?("chat_id")
            raise Rho::ConfigurationError, "telegram: target accepts chat_id and optional topic_id"
          end
          chat_id = Integer(value.fetch("chat_id").to_s, 10)
          topic_id = Integer(value.fetch("topic_id").to_s, 10) unless value["topic_id"].nil?
          unless !chat_id.zero? && (!topic_id || (chat_id.negative? && topic_id.positive?))
            raise Rho::ConfigurationError, "telegram: target needs a nonzero chat ID and topics need a group and positive topic ID"
          end
          { "chat_id" => chat_id.to_s, "topic_id" => topic_id }
        end
    end

    # Token material stays in the write-only Connection configuration.
    class ConnectionSettings
      KEYS = %w[name enabled token].freeze
      attr_reader :name, :token

      def initialize(document)
        document = document.to_h.transform_keys(&:to_s)
        unknown = document.keys - KEYS
        raise Rho::ConfigurationError, "telegram: unknown Connection setting #{unknown.first}" unless unknown.empty?

        @name = document.fetch("name", "Telegram").to_s.strip
        @enabled = document.fetch("enabled", true)
        @token = document["token"].to_s.strip
        unless !@name.empty? && @name.length <= 100 && (@enabled == true || @enabled == false)
          raise Rho::ConfigurationError, "telegram: Connection needs a name up to 100 characters and boolean enabled"
        end
      end

      def enabled? = @enabled
      def configured? = !@token.empty?
      def to_h = { "name" => name, "enabled" => enabled? }
      def inspect = "#<#{self.class} enabled=#{enabled?}>"
    end
  end
end
