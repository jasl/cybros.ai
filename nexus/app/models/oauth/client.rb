require "ipaddr"

module OAuth
  # One deployment trusts its loopback and private network by default. An
  # explicit registration list replaces that default; DNS names are never
  # resolved to decide whether they belong to the private network.
  module Client
    def self.registered?(client_id)
      [OAuth::DEVICE_CLIENT_ID, OAuth::APPLICATION_CLIENT_ID].include?(client_id)
    end

    def self.redirect_allowed?(value)
      uri = URI.parse(value)
      return false unless %w[http https].include?(uri.scheme) && uri.host.present? &&
        uri.userinfo.nil? && uri.fragment.nil? && uri.port.between?(1, 65535)

      private_network = private_network_host?(uri.hostname)
      if ENV.key?("NEXUS_OAUTH_REDIRECT_URIS")
        registered = JSON.parse(ENV.fetch("NEXUS_OAUTH_REDIRECT_URIS")).map(&:to_s)
        registered.include?(value) &&
          (uri.scheme == "https" || private_network || ENV["NEXUS_OAUTH_ALLOW_HTTP"] == "true")
      else
        private_network && uri.path == "/auth/callback" && uri.query.nil?
      end
    rescue URI::InvalidURIError
      false
    end

    def self.private_network_host?(host)
      return true if host.downcase == "localhost"

      address = IPAddr.new(host)
      address.loopback? || address.private?
    rescue IPAddr::InvalidAddressError
      false
    end
    private_class_method :private_network_host?
  end
end
