module OAuth
  # Deployment-owned callback registration. The HTTP exception is explicit for
  # LAN deployments; loopback callbacks are also usable without a certificate.
  module Client
    DEFAULT_REDIRECT_URIS = %w[
      http://127.0.0.1:7777/auth/callback
      http://localhost:7777/auth/callback
    ].freeze

    def self.registered?(client_id)
      [OAuth::DEVICE_CLIENT_ID, OAuth::APPLICATION_CLIENT_ID].include?(client_id)
    end

    def self.redirect_allowed?(value)
      uri = URI.parse(value)
      registered = JSON.parse(ENV.fetch("NEXUS_OAUTH_REDIRECT_URIS", DEFAULT_REDIRECT_URIS.to_json)).map(&:to_s)
      registered.include?(value) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil? &&
        (uri.scheme == "https" ||
          (uri.scheme == "http" &&
            (uri.hostname.in?(%w[127.0.0.1 localhost ::1]) || ENV["NEXUS_OAUTH_ALLOW_HTTP"] == "true")))
    rescue URI::InvalidURIError
      false
    end
  end
end
