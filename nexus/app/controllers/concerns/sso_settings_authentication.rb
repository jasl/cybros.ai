module SsoSettingsAuthentication
  private

    # BCrypt stays outside the Account lock. A concurrent credential change
    # invalidates this session through its existing recovery generation.
    def with_sso_settings_proof(action:, target:, excluding_provider: nil)
      supplied = params.permit(:current_password)[:current_password].to_s
      password_verified = supplied.present? && Current.identity.authenticate(supplied)
      Current.account.with_lock do
        verified = Session.find_usable(Current.session.public_id) && (
          (!Current.account.sso_only? && password_verified) ||
            Sso::Proof.consume(session: Current.session, action: action, target: target, excluding_provider: excluding_provider)
        )
        yield(verified)
      end
    end
end
