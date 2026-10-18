module API
  module ModelProviderAuthorizationPresenter
    class << self
      def current(account:, provider_id:, user:)
        status = ModelProviders::CodexAuthorization::Status.for(account:, provider_id:)
        latest = ModelProviderOAuthSession.where(account_id: account.id, provider_id:)
          .order(id: :desc).first
        {
          provider_id: provider_id,
          state: status.state,
          expires_at: status.expires_at&.iso8601,
          session: latest && session(latest, user:),
        }
      end

      def session(row, user:)
        owned = row.issuing_user_id == user.id
        reveal = owned && row.pending? && row.device_start?
        {
          public_id: row.public_id, kind: row.kind, state: row.state,
          progress: row.progress, outcome: row.outcome,
          expires_at: row.authorization_deadline_at&.iso8601,
          verification_uri: reveal ? row.verification_uri : nil,
          user_code: reveal ? row.user_code : nil,
          owned_by_current_user: owned,
        }
      end
    end
  end
end
