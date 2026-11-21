module Sso
  # A single-use operation grant, issued by an already connected, still
  # enabled identity source. Session and action arguments come from the
  # protected controller at consumption time.
  module Proof
    def self.valid?(session:, action:, target:, excluding_provider: nil)
      grants(session, action, target, excluding_provider).exists?
    end

    def self.consume(session:, action:, target:, excluding_provider: nil)
      grants(session, action, target, excluding_provider).delete_all.positive?
    end

    def self.grants(session, action, target, excluding)
      return SsoAttempt.none unless session && Session.find_usable(session.public_id)

      connected = SsoConnection.where(identity_id: session.identity_id)
        .where("sso_connections.sso_provider_id = sso_attempts.sso_provider_id AND sso_connections.subject = sso_attempts.subject")
      scope = SsoAttempt.unexpired.joins(:sso_provider)
        .where(session_id: session.id, purpose: "reauth", phase: "proved", action_name: action,
          action_target: target, sso_providers: { enabled: true })
        .where("sso_attempts.provider_version = sso_providers.lock_version")
        .where(connected.arel.exists)
      scope = scope.where.not(sso_provider_id: excluding.id) if excluding
      scope
    end
    private_class_method :grants
  end
end
