module ModelSelection
  # The accept-time resolver: file base composed with the Account's policy
  # and credentials, answering a frozen ResolvedModelSelection or a typed refusal.
  class Resolver
    CREDENTIAL_REFUSALS = {
      lane_disabled: :provider_disabled,
      no_credential: :missing_credential,
      credential_kind_mismatch: :missing_credential,
      reauthorization_required: :reauthorization_required,
      credential_unusable: :credential_unusable,
    }.freeze

    Candidate = Data.define(
      :workload, :provider_id, :model_ref, :execution_profile, :capabilities
    )

    # Selection folds every policy because it compares lanes; execution
    # folds only its provider. A row reshapes only its own lane, so the fold is order-independent.
    Catalog = Data.define(:providers, :models, :selectors, :policies, :hidden_models, :unavailable_models)

    def self.effective_catalog(account, snapshot)
      # A fresh relation, never the memoized association: admission composes
      # this once per pass and must observe policy writes since the last one.
      policies = ModelProviderConfig.where(account: account).order(:provider_id).to_a
      compose_catalog(account, snapshot, policies)
    end

    # Execution and settlement already know the exact provider. They need
    # that lane's current overlay, not every policy row on the Account.
    def self.effective_provider_catalog(account, snapshot, provider_id)
      policy = ModelProviderConfig.find_by(account: account, provider_id: provider_id)
      compose_catalog(account, snapshot, [policy].compact)
    end

    def self.compose_catalog(account, snapshot, policies)
      providers = snapshot.providers
      models = snapshot.models
      hidden_models = Set.new
      unavailable_models = Set.new
      policies.each do |policy|
        result = ModelCatalog::ProviderOverlay.apply(
          providers: providers, models: models, selectors: snapshot.selectors,
          policy: policy, account_unit: account.cost_unit, logger: Rails.logger
        )
        providers = result.providers
        models = result.models
        hidden_models.merge(result.hidden_models)
        unavailable_models.merge(result.unavailable_models)
      end

      Catalog.new(
        providers: providers,
        models: models,
        selectors: snapshot.selectors,
        policies: policies.index_by(&:provider_id),
        hidden_models: hidden_models.freeze,
        unavailable_models: unavailable_models.freeze
      )
    end
    private_class_method :compose_catalog

    def resolve(account:, workload:, submitted:, configuration: {})
      raise ArgumentError, "account is required" if account.nil?

      refusal = Workloads.refusal_for(workload: workload, submitted: submitted)
      return Result.refused(refusal) if refusal

      snapshot = begin
        ModelCatalog.current
      rescue ModelCatalog::Unavailable
        return Result.refused(:model_plane_unavailable)
      end
      catalog = effective_catalog(account, snapshot)
      selector = submitted.model_selector
      if selector
        resolve_selector(account, catalog, workload, submitted, configuration, selector)
      else
        attempt_model(
          account, catalog, workload, submitted, configuration,
          model: submitted.model, effort: submitted.reasoning_effort, enabled: submitted.reasoning_enabled
        )
      end
    end

    private

      # Candidate order is authoritative (file-owned selector policy): the
      # first candidate that passes every acceptance gate wins; a candidate
      # that fails any gate is skipped, and an exhausted list refuses.
      def resolve_selector(account, catalog, workload, submitted, configuration, selector)
        candidates = catalog.selectors[selector]
        return Result.refused(:unknown_model_selector) if candidates.nil?

        candidates.each do |candidate|
          attempt = attempt_model(
            account, catalog, workload, submitted, configuration,
            model: candidate.fetch("model"),
            effort: candidate["reasoning_effort"] || submitted.reasoning_effort,
            enabled: candidate.fetch("reasoning_enabled", submitted.reasoning_enabled)
          )
          return attempt if attempt.resolved?
        end

        Result.refused(:no_selectable_candidate)
      end

      def attempt_model(account, catalog, workload, submitted, configuration,
                        model:, effort:, enabled:)
        provider_id, model_tail = Nexus::ModelRef.parse(model).deconstruct
        return Result.refused(:unknown_provider) unless catalog.providers.key?(provider_id)

        policy = catalog.policies[provider_id]
        return Result.refused(:provider_disabled) unless policy&.enabled

        entry = catalog.models[model]
        return Result.refused(:unknown_model) if entry.nil?
        return Result.refused(:model_hidden) if catalog.hidden_models.include?(model)

        # The catalog composes it: naming a wire names the one workload it
        # serves, so an unserved workload is a composition that never happens.
        profile = ModelCatalog::ProfileBuilder.call(
          model_ref: model, provider: catalog.providers.fetch(provider_id), model: entry
        )
        return Result.refused(:unsupported_workload) unless profile.workload == workload

        credential = ModelProviders::CredentialResolver.resolve(
          account: account, provider_id: provider_id,
          credential_lane: profile.credential_lane,
          total_execution_deadline_seconds: profile.total_execution_deadline_seconds,
          now: Time.current
        )
        unless credential.resolved?
          return Result.refused(CREDENTIAL_REFUSALS.fetch(credential.outcome))
        end

        candidate = build_candidate(provider_id, model_tail, workload, entry, profile)

        reasoning, reasoning_refusal = effective_reasoning(entry, effort, enabled)
        return Result.refused(reasoning_refusal) if reasoning_refusal

        generation_config = Workloads.normalize_configuration(
          configuration: configuration, capabilities: candidate.capabilities
        )
        return Result.refused(generation_config.refusal) unless generation_config.accepted?

        Result.resolved(Nexus::ResolvedModelSelection.from_resolution(CandidateResolution.new(
          submitted: submitted,
          candidate: candidate,
          generation_config: generation_config.value,
          reasoning: reasoning,
        )))
      end

      def effective_catalog(account, snapshot) = self.class.effective_catalog(account, snapshot)

      def build_candidate(provider_id, model_tail, workload, entry, profile)
        Candidate.new(
          workload: workload,
          provider_id: provider_id,
          model_ref: model_tail,
          execution_profile: profile,
          capabilities: capability_snapshot(entry, profile)
        )
      end

      # ProfileBuilder has already composed and validated wire, provider, and
      # model facts. The durable snapshot projects that closed value directly;
      # only Nexus's advisory input threshold does not belong to the gem.
      def capability_snapshot(entry, profile)
        capabilities = entry.fetch("capabilities", {})
        authored_limits = capabilities["limits"] || entry["limits"] || {}
        Nexus::ModelCapabilitySnapshot.new(
          input_modalities: profile.input_modalities,
          output_modalities: profile.output_modalities,
          limits: capability_limits(
            profile.local_safety_limits,
            effective_input_tokens: authored_limits["effective_input_tokens"]
          ),
          prompt_caching: profile.capability_enabled?("prompt_caching"),
          streaming: profile.capability_enabled?("streaming"),
          service_tiers: profile.service_tiers,
          reasoning_modes: profile.reasoning_option_values("modes"),
          generation_parameters: generation_parameters(profile.generation_parameters),
          reasoning_replay:
            Nexus::ReasoningReplayCapability.from_h(capabilities["reasoning_replay"])
        )
      end

      def capability_limits(limits, effective_input_tokens:)
        # deconstruct_keys carries every declared bound, absent ones as nil;
        # the profile's own to_h is the compact catalog projection.
        Nexus::ModelCapabilityLimits.new(effective_input_tokens: effective_input_tokens, **limits.deconstruct_keys(nil))
      end

      def generation_parameters(parameters)
        parameters.to_h do |name, parameter|
          [name.to_sym, Nexus::ModelGenerationParameter.from_h(parameter.to_h)]
        end
      end

      # Reasoning derivation is ONE authority shared with compile-time
      # selector validation (Nexus::EffectiveReasoning.derive), so the two
      # sides cannot drift into disagreeing rules.
      def effective_reasoning(entry, effort, enabled)
        Nexus::EffectiveReasoning.derive(entry.dig("capabilities", "reasoning"), effort, enabled: enabled)
      end
  end
end
