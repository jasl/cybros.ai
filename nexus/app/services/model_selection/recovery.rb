module ModelSelection
  # An accepted execution owns its ordered routes and the caller's intent.
  # Availability is live; editing the declaration never rewrites this list.
  module Recovery
    UNAVAILABLE = %w[
      unknown_provider unknown_model model_hidden provider_disabled missing_credential
      reauthorization_required credential_unusable
    ].freeze
    Result = Data.define(:selection, :refusal, :skips) do
      def resolved? = !selection.nil?
    end

    module_function

    def resolve(account:, workload:, submitted:, model_selection:, fallback_models:, configuration:,
                excluded: [], request_body: nil, port: Resolver.new, include_current: true, &accept_candidate)
      current = submitted.model
      skips = []
      refusal = nil
      if include_current
        result = ModelSelection.resolve(account: account, workload: workload, submitted: submitted,
          configuration: configuration, port: port)
        return Result.new(selection: result.selection, refusal: nil, skips: skips) if result.resolved?
        return Result.new(selection: nil, refusal: result.refusal, skips: skips) unless UNAVAILABLE.include?(result.refusal.to_s)

        refusal = result.refusal
        skips << skip(current, refusal)
      end

      routes = [model_selection.model, *fallback_models].uniq
      position = routes.index(current)
      candidates = position ? routes.drop(position + 1) : fallback_models.uniq
      candidates.each do |reference|
        next if reference == current || excluded.include?(reference)

        word = constraint_refusal(account, model_selection, reference)
        if word
          skips << skip(reference, word)
          next
        end
        candidate = Nexus::SubmittedModelSelection.new(model: reference, reasoning_effort: nil)
        result = ModelSelection.resolve(account: account, workload: workload, submitted: candidate,
          configuration: configuration, port: port)
        word = result.resolved? ? input_refusal(result.selection, workload, request_body) : result.refusal
        word ||= accept_candidate.call(result.selection) if result.resolved? && accept_candidate
        if word
          skips << skip(reference, word)
          refusal ||= word
          next
        end

        return Result.new(selection: result.selection, refusal: nil, skips: skips)
      end
      Result.new(selection: nil, refusal: refusal || :no_selectable_fallback, skips: skips)
    end

    def skip(model, reason) = { "model" => model, "reason" => reason.to_s }

    def constraint_refusal(account, intent, reference)
      return if intent.constraint == "any" || intent.alternatives.include?(reference)
      return if reference == intent.model

      initial = Nexus::ModelRef.parse(intent.model)
      candidate = Nexus::ModelRef.parse(reference)
      if %w[provider route].include?(intent.constraint) && candidate.provider_id != initial.provider_id
        return :provider_constraint
      end
      if %w[model route].include?(intent.constraint) && !same_model?(account, intent.model, reference)
        return :model_constraint
      end
      nil
    end

    # Names, aliases and model-family prefixes prove no identity. Only two
    # catalog entries declaring the same exact version may cross a lane.
    def same_model?(account, initial, candidate)
      catalog = Resolver.effective_catalog(account, ModelCatalog.current)
      identity = catalog.models.dig(initial, "model_identity")
      identity.present? && identity == catalog.models.dig(candidate, "model_identity")
    rescue ModelCatalog::Unavailable
      false
    end

    def input_refusal(selection, workload, body)
      return if body.nil?
      return :foreign_tool_history unless AgentRuns::ModelFallback.takes_tool_history?(selection, body)

      entries = body.entry_payloads
      if entries.any? { |entry| %w[tool_call_item tool_result_item].include?(entry["type"]) } &&
          !selection.execution_profile.capability_enabled?("tool_calls")
        return ModelRequests::Build::CAPABILITY_UNAVAILABLE
      end
      input = Nexus::InputEntries.from(entries: entries, workload: workload)
      result = Workloads.accept_normalized_input(selection: selection, input: input,
        uploads: body.request_uploads(workload))
      result.accepted? ? context_refusal(selection, input) : result.refusal
    end

    def tools_refusal(selection, tools)
      ModelRequests::Build::CAPABILITY_UNAVAILABLE if tools.present? &&
        !selection.execution_profile.capability_enabled?("tool_calls")
    end

    def context_refusal(selection, input, counted: nil)
      return unless selection.workload == "text_generation"

      limit = selection.capabilities.limits.planning_input_bound
      profile = selection.execution_profile
      return if limit.nil? || profile.token_counter.nil?

      counted ||= ModelRequests::TokenCount.count(profile: profile,
        segments: Nexus::ModelRequestInput.text_segments(input))
      :estimated_input_exceeds_model_limit if counted.counted? && counted.exact? && counted.tokens > limit
    end
  end
end
