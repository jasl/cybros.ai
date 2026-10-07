module ModelProviders
  module CodexAuthorization
    # The installation status, derived and never stored: a stored copy
    # would be a second authority. Strictly side-effect free — a GET must
    # never join the CAS-mark writers.
    module Status
      Projection = Data.define(:state, :session_public_id, :verification_uri, :expires_at)

      class << self
        def for(account:, provider_id: PROVIDER_ID)
          credential = ModelProviderCredential.find_by(
            account_id: account.id, provider_id: provider_id, material_kind: "oauth_tokens"
          )
          session = ModelProviderOAuthSession
            .nonterminal.where(account_id: account.id, provider_id: provider_id).first

          Projection.new(
            state: state_for(credential, session),
            session_public_id: session&.public_id,
            # Rendered so a human can be sent back to the page they still owe a
            # code to; null once the session terminalizes and clears it.
            verification_uri: session&.verification_uri,
            expires_at: credential&.expires_at
          ).freeze
        end

        private

          # A mark wins (a human must act); a present credential reads
          # `authorized` even with a refresh in flight, or the lane flaps every
          # rotation. Expiry is the candidate predicate's question, not this read's.
          def state_for(credential, session)
            return "reauthorization_required" if credential&.reauthorization_required?
            return "authorized" if credential
            return "pending" if session

            "missing"
          end
      end
    end
  end
end
