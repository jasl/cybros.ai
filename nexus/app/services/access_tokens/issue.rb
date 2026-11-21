module AccessTokens
  class Issue
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(user:, presented_session:, current_password:, name:, note:, credential_plane:, &sso_proof)
      @sso_proof = sso_proof
      @user = user
      @presented_session = presented_session
      @current_password = current_password
      @name = name
      @note = note
      @credential_plane = credential_plane
    end

    def call
      member = current_member

      return Result.not_issuable unless member

      identity = member.identity
      password_verified = @current_password.present? && identity.authenticate(@current_password)
      digest = identity.password_digest
      identity.account.with_lock do
        identity.lock!
        member.lock!
        allowed = (!identity.account.sso_only? && password_verified && identity.password_digest == digest) || @sso_proof&.call
        if allowed
          issue_after_verification(member)
        else
          Result.invalid_password
        end
      end
    end

    private

      # Final current-state acceptance: the target must still be an active
      # human member at issuance time.
      def current_member
        User.includes(:identity).find_by(id: @user.id, kind: :human, status: :active)
      end

      def issue_after_verification(member)
        if presented_session_current?(member) && plane_grantable?(member)
          issue_for(member)
        else
          Result.not_issuable
        end
      end

      # The platform plane is minted only under the live admin role. The
      # mint-frozen plane then holds even across later promotions: a
      # member-era token can never become a platform credential.
      def plane_grantable?(member)
        @credential_plane != "platform" || member.admin?
      end

      # The presenting Session is re-resolved and must belong to the
      # password-verified member.
      def presented_session_current?(member)
        session = Session.find_usable(@presented_session&.public_id)
        session.present? && session.user_id == member.id
      end

      def issue_for(member)
        parts = AccessToken::DIGESTED.mint_parts
        token = member.access_tokens.build(
          name: @name,
          note: @note,
          credential_plane: @credential_plane,
          lookup_id: parts.lookup_id,
          secret_digest: parts.digest,
          user_authority_generation: @presented_session.user_authority_generation,
          identity_recovery_generation: @presented_session.identity_recovery_generation
        )

        if token.save
          Result.issued(token: token, secret: parts.raw)
        else
          Result.invalid(token: token)
        end
      end
  end
end
