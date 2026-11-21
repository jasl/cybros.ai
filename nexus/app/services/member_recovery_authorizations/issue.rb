module MemberRecoveryAuthorizations
  # Advances one Identity-owned recovery generation and reveals its new raw
  # secret. The Identity lock owns mint/consume ordering; this command keeps
  # supersession, fencing, and row creation in that one transaction.
  class Issue
    Result = Data.define(:outcome, :authorization, :secret) do
      class << self
        def issued(authorization:, secret:)
          new(outcome: :issued, authorization: authorization, secret: secret)
        end

        def not_recoverable
          new(outcome: :not_recoverable, authorization: nil, secret: nil)
        end

        private :new
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(user:, purpose: :password, lost_sso_provider: nil)
      @user = user
      @purpose = purpose.to_s
      @lost_sso_provider = lost_sso_provider
    end

    def call
      identity = @user&.identity

      if @user.nil? || identity.nil? || !@user.human? || !@user.active?
        Result.not_recoverable
      else
        issue_for(identity)
      end
    end

    private

      def issue_for(identity)
        parts = MemberRecoveryAuthorization::DIGESTED.mint_parts

        # The Identity lock serializes issue against consume and another issue;
        # a guarded write cannot atomically supersede, fence, and insert.
        identity.account.with_lock do
          identity.lock!
          member = identity.user
          member.lock!
          return Result.not_recoverable unless member.active?
          return Result.not_recoverable if @purpose == "password" && identity.account.sso_only?
          return Result.not_recoverable if @purpose == "sso_connection" && identity.account.sso_providers.where(enabled: true).none?
          if @lost_sso_provider && !identity.sso_connections.exists?(sso_provider: @lost_sso_provider)
            return Result.not_recoverable
          end

          MemberRecoveryAuthorization.current
            .where(identity: identity)
            .update_all(superseded_at: Time.current)
          identity.update!(
            credential_recovery_generation: identity.credential_recovery_generation + 1,
            local_recovery_pending_at: Time.current
          )
          authorization = MemberRecoveryAuthorization.create!(
            account: identity.account,
            purpose: @purpose,
            lost_sso_provider: @lost_sso_provider,
            identity: identity,
            user: @user,
            generation: identity.credential_recovery_generation,
            lookup_id: parts.lookup_id,
            secret_digest: parts.digest,
            expires_at: MemberRecoveryAuthorization::SECRET_LIFETIME.from_now
          )
          Result.issued(authorization: authorization, secret: parts.raw)
        end
      end
  end
end
