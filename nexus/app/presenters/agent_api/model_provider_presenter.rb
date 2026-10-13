module AgentAPI
  # A provider lane as the account holds it: enabled (a policy row) and
  # credentialed (a secret, unless the lane needs none) are independent facts.
  # `lock_version` rides because every mutation demands it; the secret never rides.
  class ModelProviderPresenter
    class << self
      # `now:` is the caller's clock — the controller passes `DatabaseClock.now`,
      # the admitter's own, so the lane says "held" exactly when the pass does.
      def index(account:, snapshot:, now:)
        catalog = ModelSelection::ProviderMetadata.read(account: account, snapshot: snapshot)
        policies = catalog.policies
        credentials = credentials_for(account).index_by(&:provider_id)
        runtime_states = ModelProviderRuntimeState.where(account: account).index_by(&:provider_id)
        counts = catalog.model_counts

        catalog.providers.keys.sort.map do |provider_id|
          row(provider_id: provider_id, provider: catalog.providers.fetch(provider_id),
              policy: policies[provider_id], credential: credentials[provider_id],
              runtime_state: runtime_states[provider_id], models: counts.fetch(provider_id, 0), now: now)
        end
      end

      def one(account:, provider_id:, snapshot:, now:)
        catalog = ModelSelection::ProviderMetadata.read(account: account, snapshot: snapshot, provider_id: provider_id)
        policy = catalog.policies[provider_id]
        provider = catalog.providers[provider_id]
        raise ActiveRecord::RecordNotFound if provider.nil? && policy.nil?

        row(
          provider_id: provider_id,
          provider: provider,
          policy: policy,
          credential: credentials_for(account).find_by(provider_id: provider_id),
          runtime_state: ModelProviderRuntimeState.find_by(account: account, provider_id: provider_id),
          models: provider ? catalog.model_counts.fetch(provider_id, 0) : 0,
          now: now
        )
      end

      # ONE lane row, pure over the catalog's provider hash and the three
      # account rows (or doubles shaped like them; nil for a lane nobody
      # touched) — the contract pack renders it over fixtures at a fixed `now`.
      def row(provider_id:, provider:, policy:, credential:, runtime_state:, models:, now:)
        lane = provider && ModelCatalog::ProfileBuilder.credential_lane(provider)
        {
          id: provider_id,
          display_name: provider&.fetch("display_name", nil),
          # The operator's word for how this lane authenticates, so a
          # console knows whether to offer a key field at all.
          credentials: lane,
          enabled: !provider.nil? && (policy&.enabled? || false),
          lock_version: policy&.lock_version,
          configured: !provider.nil? && (lane == "none" || !credential.nil?),
          material_kind: credential&.material_kind,
          reauthorization_required: credential&.reauthorization_required? || false,
          models: models,
          # THE PROVIDER'S OWN CLOCK: when the lane last said "not before";
          # null once that time has passed. A delay, never a readiness fact —
          # `enabled`/`configured` say whether the lane runs at all.
          unavailable_until: (runtime_state.next_admission_at if runtime_state&.floored?(now)),
        }
      end

      private

        def credentials_for(account)
          ModelProviderCredential.where(account: account).select(:provider_id, :material_kind, :reauthorization_required)
        end
    end
  end
end
