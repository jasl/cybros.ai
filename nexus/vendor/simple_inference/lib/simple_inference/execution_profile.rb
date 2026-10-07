module SimpleInference
  # One execution profile supplied by the consumer: the closed
  # (provider, adapter_profile, protocol_route, workload/model, credential
  # lane) tuple plus the validated facts the request path may rely on.
  #
  # Fail-closed by construction: every vocabulary is closed, every fact is
  # explicit, absence means DISABLED, and the per-profile
  # total_execution_deadline must be a positive, finite, bounded canonical
  # duration. An invalid profile rejects here — before any credential/file
  # read or network IO can exist downstream. Each structured fact is its
  # own value (execution_profile/*.rb); the catalog hands Hashes in and the
  # profile hands values out.
  class ExecutionProfile < Data.define(
    :profile_id, :provider_id, :adapter_profile, :protocol_route, :workload, :model_pin,
    :credential_lane, :total_execution_deadline_seconds, :stream_idle_timeout_seconds,
    :primary_execution_pair, :allowed_execution_pairs, :capabilities, :input_modalities,
    :output_modalities, :service_tiers, :generation_parameters, :wire_options, :input_media,
    :reasoning_options, :local_safety_limits, :native_cost_contract, :token_counter
  )
    require_relative "execution_profile/facts"
    require_relative "execution_profile/execution_pair"
    require_relative "execution_profile/token_counter"
    require_relative "execution_profile/native_cost_contract"
    require_relative "execution_profile/generation_parameter"
    require_relative "execution_profile/input_media_facts"
    require_relative "execution_profile/local_safety_limits"

    ADAPTER_PROFILES = %w[
      openai_responses
      codex_responses
      anthropic_messages
      gemini_generate_content
      openrouter_chat
      openai_compatible_chat
      deepseek_responses
      xai_responses
      openai_images
      openai_audio_speech
      openai_audio_transcriptions
      openai_embeddings
      gemini_embeddings
    ].freeze

    PROTOCOL_ROUTES = %w[
      responses_http_sse
      messages_http_sse
      chat_completions_http_sse
      generate_content_http_sse
      images_generations_http
      audio_speech_http
      audio_transcriptions_http_multipart
      embeddings_http
      embed_content_http
    ].freeze

    MULTIPART_PROTOCOL_ROUTES = %w[
      audio_transcriptions_http_multipart
    ].freeze

    WORKLOADS = %w[
      text_generation
      image_generation
      speech_generation
      transcription
      embedding
    ].freeze

    MODEL_RUNNER_ASYNC_HTTP_PAIR = ExecutionPair::MODEL_RUNNER_ASYNC_HTTP
    SOLID_QUEUE_HTTPX_PAIR = ExecutionPair::SOLID_QUEUE_HTTPX
    EXECUTION_PAIRS = ExecutionPair::ALL

    # `none` is the truthfully credentialless lane (the dev/mock provider,
    # spec 12 D20): no credential row exists, requests carry no
    # authorization material, and the consumer's credential snapshot is
    # entirely absent rather than partially filled.
    CREDENTIAL_LANES = %w[api_key oauth_tokens none].freeze

    # No `structured_output` word (owner 2026-09-16): structured output is
    # a wire's `response_format` declaration, offered through the
    # `output_format` generation parameter, never a capability flag.
    CAPABILITIES = %w[
      streaming
      tool_calls
      prompt_caching
      conversation_state
      provider_builtin_tools
      reasoning
    ].freeze

    INPUT_MODALITIES = %w[image audio video file].freeze
    OUTPUT_MODALITIES = %w[text image audio embedding].freeze

    PATH_WIRE_OPTION_KEYS = %i[
      responses_path
      images_path
      images_edits_path
      speech_path
      transcriptions_path
      embeddings_path
      messages_path
    ].freeze

    # stream_only: the lane's wire ACCEPTS ONLY streaming requests (the
    # Codex backend 400s non-streaming POSTs). stream_include_usage: whether
    # streamed requests ask for the final usage chunk (OpenRouter's always-on
    # accounting declares false). default_store / encrypted_reasoning_include:
    # the codex intake defaults, registry-declared construction facts.
    # mid_conversation_system: an Anthropic ROW's fact (alignment
    # 2026-09-16, F11) that `role: system` is a wire message inside
    # messages[]; the Messages protocol takes it as a construction keyword.
    BOOLEAN_WIRE_OPTION_KEYS = %i[
      use_responses_lite stream_only
      stream_include_usage default_store encrypted_reasoning_include
      mid_conversation_system
    ].freeze

    # originator / responses_lite_header: the codex non-credential protocol
    # markers (originator also marks the codex image lane). anthropic_version:
    # the pinned Messages wire-version marker. image_response_format: a
    # provider-specific Images delivery default. images_edits_encoding: how
    # the images/edits body is spelled (multipart on the public route, json
    # on the codex backend). thinking_binding: an Anthropic ROW's
    # `thinking.block_binding.prefix_mismatch_behavior` word (F10), scoped
    # by model id; the protocol validates it against its own vocabulary.
    STRING_WIRE_OPTION_KEYS = %i[
      originator responses_lite_header anthropic_version image_response_format
      images_edits_encoding thinking_binding
    ].freeze

    # A model's instruction-role layout, applied before protocol lowering.
    # This names no serving framework, and says nothing about thinking or
    # the model's complete chat template. Omission leaves the input alone.
    PROMPT_FORMATS = %w[qwen3_5].freeze
    # Generic chat hosts expose different thinking switches. This is an
    # explicit wire choice, independent of instruction layout or model name.
    REASONING_CONTROLS = %w[reasoning_effort chat_template_kwargs].freeze
    WIRE_OPTION_KEYS = (PATH_WIRE_OPTION_KEYS + BOOLEAN_WIRE_OPTION_KEYS + STRING_WIRE_OPTION_KEYS +
      %i[prompt_format reasoning_control]).freeze

    MAX_TOTAL_EXECUTION_DEADLINE_SECONDS = 3600

    # The SECOND time axis: how long a STREAM may say nothing, applied only
    # to a request that actually streams (an event-less request produces no
    # liveness by design). 120 seconds is the predecessor's own number, a
    # CEILING on the default: an undeclared lane takes the lesser of it and
    # half its own exchange budget, so by default silence may never consume
    # more than half of what the exchange was given.
    DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS = 120

    # Plain declared vocabularies (owner ruling 2026-08-13, dev/prod
    # separation): each kind lists the values the shipped adaptation accepts
    # on this lane's wire. There is no per-value evidence state — a wrong
    # declaration fails fast at the provider and the periodic adaptation
    # refresh corrects it.
    REASONING_OPTION_KINDS = %w[efforts modes contexts summaries budgets default_enabled].freeze
    REASONING_OPTION_VALUES = {
      "efforts" => %w[none minimal low medium high xhigh max ultra],
      "modes" => %w[standard pro adaptive],
      "contexts" => %w[auto current_turn all_turns],
      "summaries" => %w[none auto concise detailed summarized omitted],
      "budgets" => %w[none manual_mode_only reasoning_max_tokens],
      "default_enabled" => %w[true false],
    }.transform_values(&:freeze).freeze

    # DOES THIS LANE STREAM — the one authority. `stream_only` is WIRE TRUTH
    # (the endpoint answers 400 to a unary POST); the `streaming` capability
    # is the lane's declared transport. The consumer freezes both facts onto
    # its own durable selection, so the definition is a class method both
    # callers reach.
    def self.streams?(capabilities:, wire_options:)
      capabilities.include?("streaming") || wire_options[:stream_only] == true
    end

    def initialize(
      profile_id:,
      provider_id:,
      adapter_profile:,
      protocol_route:,
      workload:,
      model_pin:,
      credential_lane:,
      total_execution_deadline_seconds:,
      primary_execution_pair:,
      allowed_execution_pairs:,
      stream_idle_timeout_seconds: nil,
      capabilities: [],
      input_modalities: [],
      output_modalities: [],
      service_tiers: [],
      generation_parameters: {},
      wire_options: {},
      input_media: {},
      reasoning_options: {},
      local_safety_limits: {},
      native_cost_contract: nil,
      token_counter: nil
    )
      deadline = validated_deadline(total_execution_deadline_seconds)
      primary = ExecutionPair.from_h(primary_execution_pair, field: "primary_execution_pair")
      allowed = validated_execution_pairs(allowed_execution_pairs)
      unless allowed.include?(primary)
        raise SimpleInference::ConfigurationError, "primary_execution_pair must be present in allowed_execution_pairs"
      end
      modalities = Facts.closed_list(input_modalities, INPUT_MODALITIES, field: "input_modalities")
      super(
        profile_id: Facts.identity(profile_id, field: "profile_id"),
        provider_id: Facts.identity(provider_id, field: "provider_id"),
        adapter_profile: Facts.member(adapter_profile, ADAPTER_PROFILES, field: "adapter_profile"),
        protocol_route: Facts.member(protocol_route, PROTOCOL_ROUTES, field: "protocol_route"),
        workload: Facts.member(workload, WORKLOADS, field: "workload"),
        model_pin: Facts.identity(model_pin, field: "model_pin"),
        credential_lane: Facts.member(credential_lane, CREDENTIAL_LANES, field: "credential_lane"),
        total_execution_deadline_seconds: deadline,
        stream_idle_timeout_seconds: validated_idle_timeout(stream_idle_timeout_seconds, deadline),
        primary_execution_pair: primary,
        allowed_execution_pairs: allowed,
        capabilities: Facts.closed_list(capabilities, CAPABILITIES, field: "capabilities"),
        input_modalities: modalities,
        output_modalities: Facts.closed_list(output_modalities, OUTPUT_MODALITIES, field: "output_modalities"),
        service_tiers: Facts.identity_list(service_tiers, field: "service_tiers"),
        generation_parameters: validated_generation_parameters(generation_parameters),
        wire_options: validated_wire_options(wire_options, adapter_profile: adapter_profile),
        input_media: validated_input_media(input_media, modalities),
        reasoning_options: validated_reasoning_options(reasoning_options),
        local_safety_limits: LocalSafetyLimits.from_h(local_safety_limits),
        native_cost_contract: NativeCostContract.from_h(native_cost_contract),
        token_counter: TokenCounter.from_h(token_counter),
      )
    end

    # The byte-truth MIME allowlist for a declared input modality; nil when
    # the profile records no media facts for it (the lane then has nothing to
    # accept — fail closed).
    def mime_allowlist(modality)
      modality = modality.to_s
      unless INPUT_MODALITIES.include?(modality)
        raise ArgumentError, "unknown input modality #{modality.inspect}"
      end

      input_media[modality]&.mime_allowlist
    end

    def capability_enabled?(key)
      key = key.to_s
      unless CAPABILITIES.include?(key)
        raise ArgumentError, "unknown capability #{key.inspect} (known: #{CAPABILITIES.join(", ")})"
      end

      capabilities.include?(key)
    end

    def streaming? = capability_enabled?("streaming")

    def streams? = self.class.streams?(capabilities: capabilities, wire_options: wire_options)

    def multipart? = MULTIPART_PROTOCOL_ROUTES.include?(protocol_route)

    def input_modality_enabled?(kind)
      kind = kind.to_s
      unless INPUT_MODALITIES.include?(kind)
        raise ArgumentError, "unknown input modality #{kind.inspect} (known: #{INPUT_MODALITIES.join(", ")})"
      end

      input_modalities.include?(kind)
    end

    def wire_option(key)
      unless WIRE_OPTION_KEYS.include?(key)
        raise ArgumentError, "unknown wire option #{key.inspect} (known: #{WIRE_OPTION_KEYS.join(", ")})"
      end

      wire_options[key]
    end

    def reasoning_option_values(kind)
      kind = kind.to_s
      unless REASONING_OPTION_KINDS.include?(kind)
        raise ArgumentError,
              "unknown reasoning option kind #{kind.inspect} (known: #{REASONING_OPTION_KINDS.join(", ")})"
      end

      reasoning_options.fetch(kind, [].freeze)
    end

    private

    def validated_deadline(value)
      unless value.is_a?(Numeric) && !value.is_a?(Complex)
        raise SimpleInference::ConfigurationError,
              "total_execution_deadline_seconds must be a Numeric duration (got #{value.inspect})"
      end
      unless value.finite?
        raise SimpleInference::ConfigurationError, "total_execution_deadline_seconds must be finite (got #{value})"
      end
      unless value.positive?
        raise SimpleInference::ConfigurationError, "total_execution_deadline_seconds must be positive (got #{value})"
      end
      if value > MAX_TOTAL_EXECUTION_DEADLINE_SECONDS
        raise SimpleInference::ConfigurationError,
              "total_execution_deadline_seconds #{value} exceeds the release bound " \
              "(#{MAX_TOTAL_EXECUTION_DEADLINE_SECONDS})"
      end

      value
    end

    # The invariant is what makes two axes coherent rather than two numbers:
    # a silence bound at or past the total deadline can never fire, so a lane
    # that declared one would believe it had a watchdog and have none.
    def validated_idle_timeout(value, deadline)
      return [DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS, deadline / 2.0].min if value.nil?

      unless value.is_a?(Numeric) && !value.is_a?(Complex)
        raise SimpleInference::ConfigurationError,
              "stream_idle_timeout_seconds must be a Numeric duration (got #{value.inspect})"
      end
      unless value.finite?
        raise SimpleInference::ConfigurationError, "stream_idle_timeout_seconds must be finite (got #{value})"
      end
      unless value.positive?
        raise SimpleInference::ConfigurationError, "stream_idle_timeout_seconds must be positive (got #{value})"
      end
      if value >= deadline
        raise SimpleInference::ConfigurationError,
              "stream_idle_timeout_seconds #{value} must be under the total execution " \
              "deadline (#{deadline}) or it can never fire"
      end

      value
    end

    def validated_execution_pairs(pairs)
      unless pairs.is_a?(Array) && !pairs.empty?
        raise SimpleInference::ConfigurationError, "allowed_execution_pairs must be a non-empty Array"
      end

      normalized = pairs.map { |pair| ExecutionPair.from_h(pair, field: "allowed_execution_pairs") }
      if normalized.uniq.length != normalized.length
        raise SimpleInference::ConfigurationError, "allowed_execution_pairs contains duplicate pairs"
      end

      normalized.freeze
    end

    # The four open-keyed facts below arrive from the catalog as Hashes and
    # are checked once here, at the profile's ingestion boundary.
    def validated_generation_parameters(parameters)
      unless parameters.is_a?(Hash)
        raise SimpleInference::ConfigurationError, "generation_parameters must be a Hash"
      end

      normalized = parameters.transform_keys(&:to_s)
      unknown = normalized.keys - GenerationParameter::NAMES
      unless unknown.empty?
        raise SimpleInference::ConfigurationError,
              "generation_parameters contains unknown name(s): #{unknown.join(", ")}"
      end

      normalized.to_h { |name, descriptor| [-name, GenerationParameter.from_h(name, descriptor)] }.freeze
    end

    def validated_wire_options(options, adapter_profile:)
      unless options.is_a?(Hash)
        raise SimpleInference::ConfigurationError, "wire_options must be a Hash"
      end

      unknown = options.keys - WIRE_OPTION_KEYS
      unless unknown.empty?
        raise SimpleInference::ConfigurationError,
              "wire_options contains unknown key(s): #{unknown.join(", ")} (known: #{WIRE_OPTION_KEYS.join(", ")})"
      end

      options.each do |key, value|
        if key == :prompt_format
          unless value.nil? || PROMPT_FORMATS.include?(value)
            raise SimpleInference::ConfigurationError,
                  "wire option prompt_format must be one of #{PROMPT_FORMATS.join(", ")} (got #{value.inspect})"
          end
        elsif key == :reasoning_control
          unless value.nil? || REASONING_CONTROLS.include?(value)
            raise SimpleInference::ConfigurationError,
                  "wire option reasoning_control must be one of #{REASONING_CONTROLS.join(", ")} (got #{value.inspect})"
          end
          if value && adapter_profile.to_s != "openai_compatible_chat"
            raise SimpleInference::ConfigurationError, "wire option reasoning_control belongs to openai_compatible_chat"
          end
        elsif PATH_WIRE_OPTION_KEYS.include?(key)
          unless value.is_a?(String) && value.start_with?("/")
            raise SimpleInference::ConfigurationError,
                  "wire option #{key} must be an absolute path string starting with '/' (got #{value.inspect})"
          end
        elsif BOOLEAN_WIRE_OPTION_KEYS.include?(key)
          unless value == true || value == false
            raise SimpleInference::ConfigurationError,
                  "wire option #{key} must be true or false (got #{value.inspect})"
          end
        elsif STRING_WIRE_OPTION_KEYS.include?(key)
          unless value.is_a?(String) && !value.strip.empty?
            raise SimpleInference::ConfigurationError,
                  "wire option #{key} must be a non-blank String (got #{value.inspect})"
          end
        end
      end

      options.transform_values { |value| Facts.immutable(value) }.freeze
    end

    def validated_input_media(input_media, modalities)
      unless input_media.is_a?(Hash)
        raise SimpleInference::ConfigurationError, "input_media must be a Hash"
      end

      input_media.to_h do |modality, facts|
        modality = modality.to_s
        unless modalities.include?(modality)
          raise SimpleInference::ConfigurationError,
                "input_media declares facts for #{modality.inspect}, which is not a declared input modality"
        end

        [-modality, InputMediaFacts.from_h(modality, facts)]
      end.freeze
    end

    def validated_reasoning_options(reasoning_options)
      unless reasoning_options.is_a?(Hash)
        raise SimpleInference::ConfigurationError, "reasoning_options must be a Hash"
      end

      normalized = reasoning_options.transform_keys(&:to_s)
      unknown = normalized.keys - REASONING_OPTION_KINDS
      unless unknown.empty?
        raise SimpleInference::ConfigurationError,
              "reasoning_options contains unknown kind(s): #{unknown.join(", ")}"
      end

      normalized.to_h do |kind, values|
        options = Facts.closed_list(values, REASONING_OPTION_VALUES.fetch(kind), field: "reasoning_options[#{kind}]")
        raise SimpleInference::ConfigurationError, "reasoning_options[#{kind}] must not be empty" if options.empty?

        [-kind, options]
      end.freeze
    end
  end
end
