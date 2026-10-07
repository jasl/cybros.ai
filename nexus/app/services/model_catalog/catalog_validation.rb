module ModelCatalog
  # Deep validation at snapshot compile. What an entry says about its model
  # is the fact (catalog owns the models, 2026-08-21); only modality and
  # reasoning words are the wire's, and the profile build is the last check.
  module CatalogValidation
    # What an operator may write about one model; only the key is required,
    # since the wire comes from the provider and billing is opt-in.
    CAPABILITY_KEYS = %w[
      input_modalities output_modalities limits reasoning prompt_caching
      streaming service_tiers generation_parameters input_media reasoning_replay
      tool_calls
    ].freeze
    # What an operator may write about one model, and every capability key is
    # writable flat as well as nested — the compiler folds the flat form in
    # before anything reads it.
    MODEL_ENTRY_KEYS = (%w[
      api_format model_id display_name capabilities pricing deadline_seconds
      wire_options native_cost_contract
    ] + CAPABILITY_KEYS).freeze
    # Mirrors the ModelCapabilityLimits members; every reviewed bound the
    # profile declares is restated here.
    LIMIT_KEYS = %w[
      input_tokens output_tokens input_bytes input_characters audio_duration_seconds result_count
      embedding_dimensions combined_input_output_tokens effective_input_tokens
    ].freeze
    # `effective_input_tokens` is an advisory threshold no transport
    # enforces, so it is exempt from the profile mirror.
    NEXUS_ONLY_LIMIT_KEYS = %w[effective_input_tokens].freeze
    # Thinking enablement and effort are independent model declarations.
    REASONING_KEYS = %w[
      efforts default_effort modes contexts default_context summaries budget default_enabled disable_supported
    ].freeze
    GENERATION_PARAMETER_KEYS = %w[kind default minimum maximum allowed_values].freeze
    SELECTOR_NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/
    SELECTOR_CANDIDATE_KEYS = %w[model reasoning_effort reasoning_enabled].freeze
    class << self
      def validate(merged)
        providers = merged.fetch("providers", {})
        merged.fetch("models").each do |model_ref, entry|
          validate_model_entry(model_ref, entry, providers)
        end
        validate_selectors(merged.fetch("selectors", {}), merged.fetch("models"), providers)
      end

      # One composed change: every unchanged entry has a standing verdict
      # from compile, so only the rewritten entry and the selector references
      # can be newly wrong. Key presence decides, never the value: an upsert of null is a shape.
      def validate_change(models, selectors, model_ref, providers = {})
        validate_model_entry(model_ref, models.fetch(model_ref), providers) if models.key?(model_ref)
        validate_selectors(selectors, models, providers)
      end

      # A provider change can invalidate every model in its lane and any selector using one.
      def validate_provider_definition(provider_id, provider)
        ProfileBuilder.call(model_ref: "#{provider_id}/definition", provider: provider, model: {})
      rescue SimpleInference::ConfigurationError => error
        raise CompileError, "provider #{provider_id}: #{error.message}"
      end

      def validate_provider_change(models, selectors, provider_id, providers)
        validate_provider_definition(provider_id, providers.fetch(provider_id))
        models.each do |ref, entry|
          validate_model_entry(ref, entry, providers) if Nexus::ModelRef.parse(ref).provider_id == provider_id
        end
        validate_selectors(selectors, models, providers)
      end

      private

      def validate_model_entry(model_ref, entry, providers = {})
        case entry
        when Hash then nil
        else raise CompileError, "model #{model_ref}: entry must be a mapping"
        end

        unknown = entry.keys - MODEL_ENTRY_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown keys #{unknown.sort.join(", ")}"
        end

        # A model may override its provider's wire — that is how one provider
        # serves images and embeddings beside its text lanes — but only with
        # a wire this gem adapted.
        if entry["api_format"] && !SimpleInference::ApiFormat.known?(entry.fetch("api_format"))
          raise CompileError,
            "model #{model_ref}: unknown api_format #{entry.fetch("api_format").inspect}; " \
            "adapted wires are #{SimpleInference::ApiFormat::FORMATS.join(", ")}"
        end

        validate_capabilities(
          model_ref, entry.fetch("capabilities", {}), format_defaults(model_ref, entry, providers)
        )
        profiles = [composed_profile(model_ref, entry, providers)].compact
        # Billing is opt-in: an unpriced lane is one this platform does
        # not compute a cost for.
        unless entry["pricing"].nil?
          PricingValidation.validate(model_ref, entry.fetch("pricing"), profiles)
        end
      end

      # The wire's own answers, which is what a capability declaration is
      # measured against. Absent when the overlay validates one model without
      # its composition — the same skip, and the same reason, as the build.
      def format_defaults(model_ref, entry, providers)
        provider = providers[Nexus::ModelRef.parse(model_ref).provider_id]
        return {} if provider.nil?

        format = entry["api_format"] || provider["api_format"]
        return {} unless SimpleInference::ApiFormat.known?(format)

        SimpleInference::ApiFormat.defaults(format).merge(format_name: format)
      end

      def validate_selectors(selectors, models, providers)
        case selectors
        when Hash then nil
        else raise CompileError, "selectors must be a mapping"
        end

        selectors.each do |name, candidates|
          valid_name = case name
          when String then name.match?(SELECTOR_NAME_PATTERN)
          else false
          end
          unless valid_name
            raise CompileError,
              "selector name #{name.inspect} must match #{SELECTOR_NAME_PATTERN.inspect}"
          end
          valid_candidates = case candidates
          when Array then candidates.any?
          else false
          end
          unless valid_candidates
            raise CompileError, "selector #{name.inspect} candidates must be a list and must not be empty"
          end

          candidates.each_with_index do |candidate, index|
            validate_selector_candidate(name, index, candidate, models, providers)
          end
        end
      end

      def validate_selector_candidate(selector_name, index, candidate, models, providers)
        case candidate
        when Hash then nil
        else
          raise CompileError, "selector #{selector_name.inspect} candidate #{index} must be a mapping"
        end

        unknown = candidate.keys - SELECTOR_CANDIDATE_KEYS
        unless unknown.empty?
          raise CompileError,
            "selector #{selector_name.inspect} candidate #{index} has unknown keys #{unknown.sort.join(", ")}"
        end

        model_ref = candidate["model"]
        unless exact_model_ref?(model_ref)
          raise CompileError,
            "selector #{selector_name.inspect} candidate #{index} must name one exact model ref"
        end

        model = models[model_ref]
        unless model
          raise CompileError,
            "selector #{selector_name.inspect} candidate #{index} names unknown model #{model_ref.inspect}"
        end
        unless text_generation?(model_ref, model, providers)
          raise CompileError,
            "selector #{selector_name.inspect} candidate #{index} must name a text_generation model"
        end

        validate_selector_reasoning_effort(selector_name, index, candidate, model)
      end

      # A selector picks something to talk to, so an image or embedding
      # lane in one is a mistake. An unknown provider is the overlay path's skip.
      def text_generation?(model_ref, model, providers)
        provider = providers[Nexus::ModelRef.parse(model_ref).provider_id]
        return true if provider.nil?

        format = model["api_format"] || provider["api_format"]
        SimpleInference::ApiFormat.known?(format) &&
          SimpleInference::ApiFormat.workload(format) == "text_generation"
      end

      def exact_model_ref?(model_ref)
        model_ref = String.try_convert(model_ref)
        return false if model_ref.nil?
        return false unless model_ref == model_ref.strip

        provider_id, model_name = Nexus::ModelRef.parse(model_ref).deconstruct
        !provider_id.to_s.empty? && !model_name.to_s.empty?
      end

      # The resolver's own derivation: a candidate the resolver would
      # refuse cannot compile.
      def validate_selector_reasoning_effort(selector_name, index, candidate, model)
        if candidate.key?("reasoning_enabled") && ![true, false].include?(candidate["reasoning_enabled"])
          raise CompileError, "selector #{selector_name.inspect} candidate #{index} reasoning_enabled must be boolean"
        end

        _value, refusal = Nexus::EffectiveReasoning.derive(
          model.fetch("capabilities", {})["reasoning"], candidate["reasoning_effort"], enabled: candidate["reasoning_enabled"]
        )
        return if refusal.nil?

        raise CompileError, "selector #{selector_name.inspect} candidate #{index} " \
          "reasoning effort #{candidate["reasoning_effort"].inspect} is not declared for #{candidate.fetch("model")}"
      end

      # Validating an entry means building its profile and letting the gem's
      # constructor judge the wire facts. The overlay path skips the build:
      # inventing a provider would judge the entry against a wire nobody named.
      def composed_profile(model_ref, entry, providers)
        provider_id = Nexus::ModelRef.parse(model_ref).provider_id
        provider = providers[provider_id]
        return nil if provider.nil?

        ProfileBuilder.call(model_ref: model_ref, provider: provider, model: entry)
      rescue SimpleInference::ConfigurationError => error
        raise CompileError, "model #{model_ref}: #{error.message}"
      end

      def validate_capabilities(model_ref, capabilities, defaults)
        case capabilities
        when Hash then nil
        else raise CompileError, "model #{model_ref}: capabilities must be a mapping"
        end

        unknown = capabilities.keys - CAPABILITY_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown capability keys #{unknown.sort.join(", ")}"
        end

        if capabilities.key?("input_modalities")
          validate_modalities(model_ref, capabilities.fetch("input_modalities"), defaults)
        end
        if capabilities.key?("output_modalities")
          validated_string_list(
            model_ref, capabilities.fetch("output_modalities"),
            field: "output_modalities", allow_empty: false
          )
        end
        validate_limits(model_ref, capabilities.fetch("limits")) if capabilities.key?("limits")
        validate_reasoning(model_ref, capabilities["reasoning"], defaults)
        if capabilities.key?("reasoning_replay")
          validate_reasoning_replay(
            model_ref, capabilities.fetch("reasoning_replay"), defaults[:format_name]
          )
        end
        # The three feature booleans are the wires' defaults: silent is the
        # wire's answer, `false` the one opt-out, `true` says nothing more —
        # the profile build derives each from the lowering's fact, so only
        # the shape is checked here.
        %w[prompt_caching streaming tool_calls].each do |key|
          validate_boolean_capability(model_ref, capabilities, key)
        end
        if capabilities.key?("service_tiers")
          validated_string_list(
            model_ref, capabilities.fetch("service_tiers"),
            field: "service_tiers", allow_empty: true
          )
        end
        if capabilities.key?("generation_parameters")
          validate_generation_parameters(model_ref, capabilities.fetch("generation_parameters"))
        end
      end

      def validate_boolean_capability(model_ref, capabilities, key)
        return unless capabilities.key?(key)
        return if [true, false].include?(capabilities.fetch(key))

        raise CompileError, "model #{model_ref}: capability #{key} must be boolean"
      end

      # Each native replay shape is speakable on exactly one wire family —
      # a mismatch would silently emit blocks the protocol forwards
      # verbatim to a provider that never accepts them.
      NATIVE_REPLAY_WIRES = {
        "anthropic_thinking" => %w[anthropic_messages],
        "responses_reasoning" => %w[openai_responses codex_responses xai_responses],
        "gemini_thought" => %w[gemini_generate_content],
        "chat_reasoning" => %w[openrouter_chat],
        "responses_reasoning_text" => %w[deepseek_responses],
      }.freeze
      # The format is the row's replay shape (how much is replayed is the
      # kernel's rule, the same on every row), and `required_for_tool_rounds`
      # the vendor's refusal of a tool round sent back without its reasoning.
      REASONING_REPLAY_KEYS = %w[format required_for_tool_rounds].freeze

      # A closed vocabulary: a typo'd replay format would silently replay
      # nothing.
      def validate_reasoning_replay(model_ref, declared, api_format)
        case declared
        when Hash then nil
        else raise CompileError, "model #{model_ref}: reasoning_replay must be a mapping"
        end

        unknown = declared.keys - REASONING_REPLAY_KEYS
        unless unknown.empty?
          raise CompileError,
            "model #{model_ref}: unknown reasoning_replay keys #{unknown.sort.join(", ")}"
        end
        format = declared.fetch("format", nil)
        unless Nexus::ReasoningReplayCapability::FORMATS.include?(format)
          raise CompileError,
            "model #{model_ref}: reasoning_replay format must be one of " \
            "#{Nexus::ReasoningReplayCapability::FORMATS.join(", ")}"
        end
        wires = NATIVE_REPLAY_WIRES[format]
        if wires && api_format && !wires.include?(api_format)
          raise CompileError,
            "model #{model_ref}: reasoning_replay format #{format} is not " \
            "something the #{api_format} wire speaks"
        end
        if declared.key?("required_for_tool_rounds") && ![true, false].include?(declared["required_for_tool_rounds"])
          raise CompileError, "model #{model_ref}: reasoning_replay required_for_tool_rounds must be boolean"
        end
      end

      # What a model offers, not the wire: a declaration replaces the
      # format's table, and only self-consistency is checked.
      def validate_generation_parameters(model_ref, parameters)
        case parameters
        when Hash then nil
        else raise CompileError, "model #{model_ref}: generation_parameters must be a mapping"
        end

        parameters.each do |name, descriptor|
          validate_generation_parameter(model_ref, name, descriptor)
        end
      end

      # `output_format` is the one control the wire offers unasked, so
      # `false` under it is the row's opt-out (the profile build then
      # synthesizes nothing); every other control is a mapping or absent.
      def validate_generation_parameter(model_ref, name, descriptor)
        return if name == "output_format" && descriptor == false

        case descriptor
        when Hash then nil
        else
          raise CompileError,
            "model #{model_ref}: generation parameter #{name} must be a mapping"
        end

        unknown = descriptor.keys - GENERATION_PARAMETER_KEYS
        missing = GENERATION_PARAMETER_KEYS - descriptor.keys
        unless unknown.empty?
          raise CompileError,
            "model #{model_ref}: generation parameter #{name} has unknown keys #{unknown.join(", ")}"
        end
        unless missing.empty?
          raise CompileError,
            "model #{model_ref}: generation parameter #{name} omits keys #{missing.join(", ")}"
        end

        validate_parameter_default(model_ref, name, descriptor)
      end

      def validate_parameter_default(model_ref, name, descriptor)
        allowed = descriptor.fetch("allowed_values")
        value = descriptor.fetch("default")
        unless allowed.nil?
          valid_allowed = case allowed
          when Array then !allowed.empty? && allowed.uniq.length == allowed.length
          else false
          end
          unless valid_allowed
            raise CompileError,
              "model #{model_ref}: generation parameter #{name} allowed_values must be a " \
              "non-empty unique list"
          end
          # No default means "available, send nothing unless asked", as the
          # range branch reads it; a defaulted control is sent on every turn.
          return if value.nil?

          unless allowed.include?(value)
            raise CompileError,
              "model #{model_ref}: generation parameter #{name} default #{value.inspect} is not " \
              "among its allowed values"
          end
          return
        end

        minimum = descriptor.fetch("minimum")
        maximum = descriptor.fetch("maximum")
        if minimum && maximum && minimum > maximum
          raise CompileError,
            "model #{model_ref}: generation parameter #{name} minimum exceeds its maximum"
        end
        return if value.nil?
        return unless (minimum && value < minimum) || (maximum && value > maximum)

        raise CompileError,
          "model #{model_ref}: generation parameter #{name} default #{value.inspect} is outside " \
          "its own range"
      end

      # The vocabulary is the wire's (`xhigh` is a word some wires know);
      # which words a model supports is its own narrowing.
      def validate_reasoning(model_ref, reasoning, defaults)
        return if reasoning.nil?

        reasoning = Hash.try_convert(reasoning) ||
          raise(CompileError, "model #{model_ref}: reasoning must be a mapping")

        unknown = reasoning.keys - REASONING_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown reasoning keys #{unknown.sort.join(", ")}"
        end

        known = Hash(defaults[:reasoning_options])
        efforts = known_list(model_ref, reasoning, "efforts", known)
        if efforts&.include?("none")
          raise CompileError, "model #{model_ref}: reasoning efforts cannot include none; use reasoning_enabled to disable thinking"
        end
        known_list(model_ref, reasoning, "modes", known)
        contexts = known_list(model_ref, reasoning, "contexts", known)
        known_list(model_ref, reasoning, "summaries", known)

        member_of(model_ref, reasoning, "default_effort", efforts)
        member_of(model_ref, reasoning, "default_context", contexts)

        known_member(model_ref, reasoning, "budget", "budgets", known)
        %w[default_enabled disable_supported].each do |key|
          if reasoning.key?(key) && ![true, false].include?(reasoning[key])
            raise CompileError, "model #{model_ref}: reasoning #{key} must be boolean"
          end
        end
        if reasoning["default_enabled"] == false && reasoning["disable_supported"] != true
          raise CompileError, "model #{model_ref}: reasoning default_enabled false requires disable_supported true"
        end
      end

      # Returns the declared list (or nil) after proving every member is a
      # word this wire knows.
      def known_list(model_ref, reasoning, key, known)
        return nil unless reasoning.key?(key)

        values = validated_string_list(
          model_ref, reasoning.fetch(key), field: "reasoning #{key}", allow_empty: false
        )

        unknown = values - Array(known[key])
        unless unknown.empty?
          raise CompileError,
            "model #{model_ref}: reasoning #{key} carries value(s) its wire does not know: " \
            "#{unknown.sort.join(", ")}"
        end
        values
      end

      def member_of(model_ref, reasoning, key, allowed)
        return unless reasoning.key?(key)

        value = reasoning.fetch(key)
        return if allowed&.include?(value)

        raise CompileError,
          "model #{model_ref}: reasoning #{key} #{value.inspect} is not among its declared values"
      end

      def known_member(model_ref, reasoning, key, format_key, known)
        return unless reasoning.key?(key)

        value = reasoning.fetch(key).to_s
        return if Array(known[format_key]).include?(value)

        raise CompileError,
          "model #{model_ref}: reasoning #{key} #{reasoning.fetch(key).inspect} is not known to " \
          "its wire"
      end

      # A modality is a promise the wire has to keep: an input the wire has
      # no encoding for would be an unbounded upload rather than a refused
      # one. Absent means text only; present-and-null still refuses.
      def validate_modalities(model_ref, modalities, defaults)
        modalities = validated_string_list(
          model_ref, modalities, field: "input_modalities", allow_empty: true
        )

        excess = modalities - Hash(defaults[:input_media]).keys
        return if excess.empty?

        raise CompileError,
          "model #{model_ref}: input_modalities #{excess.sort.join(", ")} have no media contract " \
          "on this wire"
      end

      def validate_limits(model_ref, limits)
        case limits
        when Hash then nil
        else raise CompileError, "model #{model_ref}: limits must be a mapping"
        end

        unknown = limits.keys - LIMIT_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown limit keys #{unknown.sort.join(", ")}"
        end

        limits.each do |key, value|
          case key
          when "embedding_dimensions"
            validate_embedding_dimensions(model_ref, value)
          else
            validate_positive_limit(model_ref, key, value)
          end
        end

        validate_window_coherence(model_ref, limits)
      end

      # A shared window refuses a second answer to the same question: an
      # independent `input_tokens` window beside it leaves selection no rule.
      COMBINED_COMPANION_KEYS = %w[
        combined_input_output_tokens output_tokens effective_input_tokens
      ].freeze

      def validate_window_coherence(model_ref, limits)
        combined = limits["combined_input_output_tokens"]
        hard = combined || limits["input_tokens"]

        if combined
          conflicting = limits.keys - COMBINED_COMPANION_KEYS
          unless conflicting.empty?
            raise CompileError,
              "model #{model_ref}: combined token contract cannot mix independent limits " \
              "#{conflicting.join(", ")}"
          end
        end

        soft = limits["effective_input_tokens"]
        return if soft.nil? || hard.nil? || soft <= hard

        raise CompileError,
          "model #{model_ref}: effective_input_tokens #{soft} exceeds the hard window #{hard}"
      end

      def validate_embedding_dimensions(model_ref, value)
        case value
        when Array
          unless value.any? && value.all? { |dimension| positive_integer?(dimension) } &&
              value.uniq.length == value.length
            raise CompileError,
              "model #{model_ref}: limit embedding_dimensions must list unique positive integers"
          end
        else
          raise CompileError,
            "model #{model_ref}: limit embedding_dimensions must list unique positive integers"
        end
      end

      def validate_positive_limit(model_ref, key, value)
        return if positive_integer?(value)

        raise CompileError, "model #{model_ref}: limit #{key} must be a positive integer"
      end

      def positive_integer?(value)
        integer = Integer(value, exception: false)
        !integer.nil? && value.eql?(integer) && integer.positive?
      end

      def validated_string_list(model_ref, values, field:, allow_empty:)
        case values
        when Array then nil
        else raise CompileError, "model #{model_ref}: #{field} must be a list"
        end

        if !allow_empty && values.empty?
          raise CompileError, "model #{model_ref}: #{field} must not be empty"
        end
        values.each do |value|
          case value
          when String then nil
          else raise CompileError, "model #{model_ref}: #{field} values must be strings"
          end
        end
        if values.uniq.length != values.length
          raise CompileError, "model #{model_ref}: #{field} contains duplicate values"
        end

        values
      end
    end
  end
end
