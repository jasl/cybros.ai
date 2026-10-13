module AgentAPI
  class ModelPresenter
    class << self
      def index(account:, catalog:, now: Time.current)
        ModelCatalog::Discovery.index(account: account, catalog: catalog, now: now)
      end

      def row(ref:, entry:, provider_id:, provider:, refusal:, account_unit:, visible: true)
        ModelCatalog::Discovery.row(ref: ref, entry: entry, provider_id: provider_id, provider: provider,
          refusal: refusal, account_unit: account_unit, visible: visible)
      end
    end
  end
end
