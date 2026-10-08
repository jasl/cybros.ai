module Rho
  module IngressTelegram
    # This adapter consumes its own opaque settings; rho resolves its plugin schema before registration.
    class Settings
      KEYS = %w[token token_env owner_id stale_after input_debounce_seconds transcription_model speech_model].freeze

      attr_reader :owner_id, :stale_after, :input_debounce_seconds, :transcription_model, :speech_model, :token_env, :token_source

      def initialize(document, env: ENV)
        document = document.to_h.transform_keys(&:to_s)
        unknown = document.keys - KEYS
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        @token_env = document.fetch("token_env", "RHO_TELEGRAM_BOT_TOKEN").to_s.strip
        raise Rho::ConfigurationError, "telegram: token_env is required" if @token_env.empty?

        @token = document["token"].to_s.strip
        @token_source = @token.empty? ? "environment" : "saved"
        @token = env.fetch(@token_env, "").to_s.strip if @token.empty?
        @token_source = "none" if @token.empty?
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
      rescue ArgumentError, TypeError
        raise Rho::ConfigurationError, Locales::ENGLISH.fetch("settings_integers_required")
      end

      def token = @token
      def enabled? = !@token.empty?
      def owner?(user_id) = !@owner_id.nil? && @owner_id == user_id.to_s
      def to_h = (KEYS - ["token"]).to_h { |key| [key, public_send(key)] }
      def inspect = "#<#{self.class} enabled=#{enabled?}>"
    end
  end
end
