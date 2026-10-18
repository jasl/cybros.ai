module ModelProviders
  module CodexAuthorization
    # Local-only clear, no provider IO: an operator pressing "disconnect"
    # must get a durable answer whatever the issuer does. Lock order is the
    # forward order every other writer uses — Policy, sessions, Credential.
    class ClearAuthorization
      Result = Data.define(:outcome, :revoked_sessions, :cleared_credential) do
        def cleared? = outcome == :cleared
      end

      def self.call(account:, provider_id: PROVIDER_ID, reason: "operator_revoked",
        now: Time.current)
        new(account:, provider_id:, reason:, now:).call
      end

      def initialize(account:, provider_id:, reason:, now:)
        @account = account
        @provider_id = provider_id
        @reason = reason
        @now = now
      end

      def call
        ModelProviderOAuthSession.transaction do
          policy = lock_policy_lane
          unless policy
            next Result.new(
              outcome: :cleared, revoked_sessions: 0, cleared_credential: :not_found
            )
          end

          revoked = ModelProviderOAuthSession.revoke_for_provider(
            account: @account, provider_id: @provider_id, reason: @reason, now: @now
          )
          cleared = clear_credential
          Result.new(outcome: :cleared, revoked_sessions: revoked, cleared_credential: cleared)
        end
      end

      private

        def lock_policy_lane
          ModelProviderConfig.lock.find_by(
            account_id: @account.id, provider_id: @provider_id
          )
        end

        # Delegated rather than reimplemented: the credential-clear primitive
        # already owns the projection change, and a second copy here would be
        # a second answer to "is this lane usable".
        def clear_credential
          ClearOAuth.call(account: @account, provider_id: @provider_id).outcome
        end
    end
  end
end
