module ModelProviderOAuthSessions
  # The refresh clock's shell: a token_refresh session for every pair
  # `ModelProviderCredential.refresh_due` names. No authority — AcceptSession
  # rechecks everything, so running late, twice, or not at all changes only when.
  class RefreshDueJob < ApplicationJob
    queue_as :default

    def perform(limit: 25)
      ModelProviderCredential.refresh_due(
        provider_id: ModelProviders::CodexAuthorization::PROVIDER_ID, limit: limit, now: Time.current
      ).each do |credential|
        ModelProviders::CodexAuthorization::AcceptSession.call(
          account: credential.account, issuing_user: User.find_by!(role: "owner"), kind: "token_refresh"
        )
      end
    end
  end
end
