module ModelInvocations
  # Admission chooses priced, free, or unmetered execution from the current
  # effective catalog, Account overlay composed in.
  class AdmissionCandidate
    # Known-free is the row's own schedule: every rate zero under a formula
    # the provider cannot re-quote. Unknown pricing is recorded as unmetered.
    CATALOG_ONLY = "catalog_only".freeze

    # The lane left the catalog between acceptance and admission.
    UNKNOWN_MODEL = :unknown_model
    # The provider was switched off after acceptance: the same
    # snapshot-validity rung as the two above.
    PROVIDER_DISABLED = :provider_disabled

    Result = Data.define(:shape, :refusal) do
      def self.known_free = new(shape: "admitted_free", refusal: nil)

      # Priced work admits without a reservation; in-flight and unsettled
      # work can overspend the budget.
      def self.priced = new(shape: "priced", refusal: nil)

      # Missing or unresolved pricing leaves money unknown while usage is recorded.
      def self.unmetered = new(shape: "unmetered", refusal: nil)

      def self.refused(refusal)
        new(shape: nil, refusal: refusal)
      end

      def accepted? = refusal.nil?
      def known_free? = shape == "admitted_free"
      def unmetered? = shape == "unmetered"
    end

    def self.call(...) = new(...).call

    def initialize(invocation:, catalog: nil)
      @invocation = invocation
      @catalog = catalog
    end

    def call
      # The Invocation stores the provider and model tail separately; the
      # catalog is keyed by the namespaced ref they compose to.
      catalog_ref = "#{@invocation.provider_id}/#{@invocation.model_ref}"
      entry = catalog.models[catalog_ref]
      return Result.refused(UNKNOWN_MODEL) if entry.nil?
      return Result.refused(PROVIDER_DISABLED) unless
        catalog.policies[@invocation.provider_id]&.enabled
      return Result.refused(:model_hidden) if catalog.hidden_models.include?(catalog_ref)

      pricing = ModelCatalog::EffectivePricing.project(
        entry: entry, model_ref: catalog_ref,
        provider: catalog.providers[@invocation.provider_id],
        account_unit: @invocation.account.cost_unit
      )
      return Result.unmetered if pricing.unmetered? || pricing.cost_unknown?
      return Result.known_free if known_free?(pricing)

      Result.priced
    end

    private

      def known_free?(pricing)
        pricing.known_free_candidate? && pricing.source_policy == CATALOG_ONLY
      end

      def catalog
        @catalog ||= ModelSelection::Resolver.effective_catalog(
          @invocation.account, ModelCatalog.current
        )
      end
  end
end
