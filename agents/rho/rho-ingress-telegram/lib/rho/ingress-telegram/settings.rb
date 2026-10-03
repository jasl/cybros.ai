module Rho
  module IngressTelegram
    # This adapter consumes its own opaque settings; rho owns only the containing object.
    class Settings
      KEYS = %w[token_env owner_id stale_after transcription_model speech_model].freeze

      attr_reader :owner_id, :stale_after, :transcription_model, :speech_model, :token_env, :token_source

      def initialize(document, home: nil, env: ENV)
        document = document.to_h.transform_keys(&:to_s)
        unknown = document.keys - KEYS
        raise Rho::ConfigurationError, "telegram: unknown setting #{unknown.first}" unless unknown.empty?

        @token_env = document.fetch("token_env", "RHO_TELEGRAM_BOT_TOKEN").to_s.strip
        raise Rho::ConfigurationError, "telegram: token_env is required" if @token_env.empty?

        @token = home ? TokenFile.new(home).read : ""
        @token_source = @token.empty? ? "environment" : "saved"
        @token = env.fetch(@token_env, "").to_s.strip if @token.empty?
        @token_source = "none" if @token.empty?
        @owner_id = Integer(document.fetch("owner_id").to_s, 10).to_s unless document["owner_id"].nil?
        @stale_after = Integer(document.fetch("stale_after", 600).to_s, 10)
        @transcription_model = document["transcription_model"].to_s.strip
        @speech_model = document["speech_model"].to_s.strip
        unless (!@owner_id || @owner_id.to_i.positive?) && @stale_after.positive?
          raise Rho::ConfigurationError, "telegram: owner_id and stale_after must be positive"
        end
      rescue ArgumentError, TypeError
        raise Rho::ConfigurationError, "telegram: owner_id and stale_after must be integers"
      end

      def token = @token
      def enabled? = !@token.empty?
      def owner?(user_id) = !@owner_id.nil? && @owner_id == user_id.to_s
      def to_h = KEYS.to_h { |key| [key, public_send(key)] }
      def inspect = "#<#{self.class} enabled=#{enabled?}>"
    end
  end
end
