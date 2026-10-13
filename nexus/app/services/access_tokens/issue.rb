module AccessTokens
  class Issue
    Result = Data.define(:outcome, :token, :secret) do
      class << self
        def issued(token:, secret:)
          new(outcome: :issued, token: token, secret: secret)
        end

        def invalid_password
          new(outcome: :invalid_password, token: nil, secret: nil)
        end

        def not_issuable
          new(outcome: :not_issuable, token: nil, secret: nil)
        end

        def invalid(token:)
          new(outcome: :invalid, token: token, secret: nil)
        end

        private :new
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(user:, presented_session:, current_password:, name:, note:, credential_plane:)
      @user = user
      @presented_session = presented_session
      @current_password = current_password
      @name = name
      @note = note
      @credential_plane = credential_plane
    end

    def call
      member = current_member

      if member.nil?
        Result.not_issuable
      elsif !member.identity.authenticate(@current_password)
        Result.invalid_password
      else
        issue_after_password_verification(member)
      end
    end

    private

      # Final current-state acceptance: the target must still be an active
      # human member at issuance time.
      def current_member
        User.includes(:identity).find_by(id: @user.id, kind: :human, status: :active)
      end

      def issue_after_password_verification(member)
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
          user_authority_generation: member.authority_generation,
          identity_recovery_generation: member.identity.credential_recovery_generation
        )

        if token.save
          Result.issued(token: token, secret: parts.raw)
        else
          Result.invalid(token: token)
        end
      end
  end
end
