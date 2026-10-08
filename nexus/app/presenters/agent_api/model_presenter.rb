module AgentAPI
  # What an account can actually run: the selection gates in the order the
  # resolver applies them, with the specific reason for an unavailable model's
  # visibility restriction. Pricing is the catalog's own effective projection.
  class ModelPresenter
    # Only the refusals a listing can answer without a request in hand;
    # everything past the credential gate depends on what is asked.
    class << self
      def index(account:, catalog:, now: Time.current)
        catalog.models.filter_map do |ref, entry|
          provider_id = Nexus::ModelRef.parse(ref).provider_id
          provider = catalog.providers[provider_id]
          next if provider.nil?

          visible = !catalog.hidden_models.include?(ref)
          refusal = if !catalog.policies[provider_id]&.enabled
            "provider_disabled"
          elsif catalog.unavailable_models.include?(ref)
            "model_unavailable"
          elsif !visible
            "model_hidden"
          elsif ModelCatalog.model_base_url(ref, snapshot: catalog).nil?
            "endpoint_unconfigured"
          else
            refusal_for(account: account, catalog: catalog, provider_id: provider_id,
                        profile: profile(ref, provider, entry), now: now)
          end
          row(ref: ref, entry: entry, provider_id: provider_id, provider: provider,
              refusal: refusal, account_unit: account.cost_unit, visible: visible)
        end.sort_by { |model| model.fetch(:ref) }
      end

      # ONE row, pure over the catalog's own entry and provider hashes, the
      # resolver's refusal word (nil: it will run) and the account's cost
      # unit — so the contract pack renders the same row the route serves
      # over a fixture entry, with no account or compiled catalog in hand.
      def row(ref:, entry:, provider_id:, provider:, refusal:, account_unit:, visible: true)
        profile = profile(ref, provider, entry)
        {
          ref: ref,
          provider: provider_id,
          workload: profile.workload,
          visible: visible,
          available: refusal.nil?,
          unavailable_reason: refusal,
          capabilities: capabilities(entry, profile),
          pricing: pricing(entry: entry, account_unit: account_unit, ref: ref, provider: provider),
        }
      end

      private

        def profile(ref, provider, entry)
          ModelCatalog::ProfileBuilder.call(model_ref: ref, provider: provider, model: entry)
        end

        # The resolver's own words, through its own table: the credential
        # resolver's vocabulary names refusals the authoring door never emits.
        def refusal_for(account:, catalog:, provider_id:, profile:, now:)
          credential = ModelProviders::CredentialResolver.resolve(
            account: account, provider_id: provider_id,
            credential_lane: profile.credential_lane,
            total_execution_deadline_seconds: profile.total_execution_deadline_seconds,
            now: now
          )
          return nil if credential.resolved?

          ModelSelection::Resolver::CREDENTIAL_REFUSALS.fetch(credential.outcome).to_s
        end

        # `tool_calls` is the one a coding agent cares about: without it a
        # model cannot drive a loop with tools, and choosing it wastes a round.
        # An agent reads facts from the kernel, never from a pack. Structured
        # output is no flag: it is the `output_format` control every text
        # wire offers, read where the caller's configuration is accepted.
        def capabilities(entry, profile)
          {
            tool_calls: profile.capability_enabled?("tool_calls"),
            streaming: profile.capability_enabled?("streaming"),
            prompt_caching: profile.capability_enabled?("prompt_caching"),
            input_modalities: profile.input_modalities,
            output_modalities: profile.output_modalities,
            reasoning_modes: profile.reasoning_option_values("modes"),
            reasoning: reasoning(entry, profile),
            generation_parameters: profile.generation_parameters.transform_values(&:to_h),
            service_tiers: profile.service_tiers,
            limits: Nexus::ModelCapabilityLimits.from_catalog(entry: entry, profile: profile).to_h.compact,
          }
        end

        def reasoning(entry, profile)
          declaration = entry.dig("capabilities", "reasoning") || {}
          defaults, = Nexus::EffectiveReasoning.derive(declaration, nil)
          {
            supported: !defaults.enabled.nil?,
            default_enabled: defaults.enabled,
            disable_supported: declaration.fetch("disable_supported", false),
            efforts: profile.reasoning_option_values("efforts"),
            default_effort: defaults.effort,
          }
        end

        def pricing(entry:, account_unit:, ref:, provider:)
          result = ModelCatalog::EffectivePricing.project(
            entry: entry, account_unit: account_unit, model_ref: ref, provider: provider
          )
          {
            state: result.state.to_s,
            unit: result.account_unit,
            # Strings, not floats: these are money, and the catalog states
            # them as decimal strings for the same reason.
            input_per_mtok: result.rates["input_per_mtok"]&.to_s("F"),
            output_per_mtok: result.rates["output_per_mtok"]&.to_s("F"),
          }.compact
        end
    end
  end
end
