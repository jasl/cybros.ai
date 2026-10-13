module ModelProviders
  # Codex's concrete authorization adapter. These wire values identify the
  # upstream flow Nexus implements; changing them means changing this adapter,
  # its focused tests, and the resulting product behavior together.
  module CodexAuthorization
    PROVIDER_ID = "codex_subscription".freeze
    ISSUER = "https://auth.openai.com".freeze
    CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann".freeze

    # The device-auth pair, token endpoint, and human verification page are
    # distinct upstream paths, so the adapter names them independently.
    USER_CODE_PATH = "/api/accounts/deviceauth/usercode".freeze
    DEVICE_TOKEN_PATH = "/api/accounts/deviceauth/token".freeze
    TOKEN_PATH = "/oauth/token".freeze
    VERIFICATION_PATH = "/codex/device".freeze
    REDIRECT_PATH = "/deviceauth/callback".freeze

    # The provider sends poll intervals as strings. This adapter enforces the
    # canonical decimal spelling; ModelProviderOAuthSession owns the domain
    # range applied after parsing.
    CANONICAL_INTERVAL = /\A(?:0|[1-9][0-9]*)\z/

    class << self
      def user_code_url = "#{ISSUER}#{USER_CODE_PATH}"
      def device_token_url = "#{ISSUER}#{DEVICE_TOKEN_PATH}"
      def token_url = "#{ISSUER}#{TOKEN_PATH}"
      def verification_url = "#{ISSUER}#{VERIFICATION_PATH}"
      def redirect_uri = "#{ISSUER}#{REDIRECT_PATH}"
    end
  end
end
