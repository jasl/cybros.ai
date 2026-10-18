module ModelRequests
  # The one translation from Nexus's provider-neutral vocabulary to a
  # lane's wire spelling, keyed by `adapter_profile`. An unmapped key is
  # refused, never dropped or smuggled through `extra_body`.
  module WireLowering
    # Two classes because the seam has two: required arguments and declared
    # options. Identity mappings are written out so the table reads as a contract.
    TABLE = {
      # `service_tier` and `verbosity` are the two request-struct fields
      # both references carry (codex-rs ResponsesApiRequest, opencode
      # openai-responses.ts): the tier is a per-request fact Build lowers
      # under codex's rule (`lower_service_tier`), the verbosity a row's
      # generation parameter lowered 1:1 into `text.verbosity`.
      "openai_responses" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
          "service_tier" => :service_tier,
          "verbosity" => :verbosity,
        }.freeze,
      }.freeze,
      # The Responses row minus `max_output_tokens`: the codex protocol's
      # declaration subtracts that one key (the pinned codex-rs request
      # struct never carries it), and the declared-kwargs contract test
      # reads the subtraction.
      "codex_responses" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "top_p" => :top_p,
          "output_format" => :response_format,
          "service_tier" => :service_tier,
          "verbosity" => :verbosity,
        }.freeze,
      }.freeze,
      # `images` is an EDIT's source images: Build merges the bound
      # uploads onto it, and the protocol retargets the compile to its
      # edits route when it is present.
      "openai_images" => {
        arguments: {}.freeze,
        options: { "result_count" => :n, "images" => :images }.freeze,
      }.freeze,
      "openai_audio_speech" => {
        arguments: { "voice" => :voice }.freeze,
        options: { "format" => :response_format }.freeze,
      }.freeze,
      "openai_audio_transcriptions" => {
        arguments: {}.freeze,
        options: { "language" => :language }.freeze,
      }.freeze,
      "openai_embeddings" => {
        arguments: {}.freeze,
        options: { "dimensions" => :dimensions }.freeze,
      }.freeze,
      # Gemini's embed lane maps both spellings onto `outputDimensionality`;
      # the returned vector's length proves it crossed.
      "gemini_embeddings" => {
        arguments: {}.freeze,
        options: { "dimensions" => :dimensions }.freeze,
      }.freeze,
      # The OpenAI-compatible rows and the direct lanes, each written from
      # its protocol's own `request_option_keys`. What is not mapped is
      # deliberate: only Gemini declares `seed`, and Gemini rejects
      # `temperature`/`top_p`/`top_k`/`n` locally.
      #
      # The anthropic row's `thinking_binding` is a WIRE-OPTION fact,
      # not a control: the row's `wire_options: { thinking_binding:
      # drop_block }` reaches the protocol's construction keyword through
      # `ApiFormat.protocol_for`, and the protocol lowers it into
      # `thinking.block_binding.prefix_mismatch_behavior` on adaptive and
      # enabled thinking, implying its beta. Scoped by MODEL ID (fable-5-1,
      # opus-5-5), never by lane; this row is the register that says so.
      "anthropic_messages" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
        }.freeze,
      }.freeze,
      "deepseek_responses" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
        }.freeze,
      }.freeze,
      "xai_responses" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
        }.freeze,
      }.freeze,
      "gemini_generate_content" => {
        arguments: {}.freeze,
        options: {
          "max_output_tokens" => :max_output_tokens,
          "seed" => :seed,
          "output_format" => :response_format,
        }.freeze,
      }.freeze,
      # The generic third-party-host dialect; without this row every control
      # is refused before a socket opens.
      "openai_compatible_chat" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
          "seed" => :seed,
        }.freeze,
      }.freeze,
      "openrouter_chat" => {
        arguments: {}.freeze,
        options: {
          "temperature" => :temperature,
          "max_output_tokens" => :max_output_tokens,
          "top_p" => :top_p,
          "output_format" => :response_format,
          # A determinism control is a product fact: a caller who cannot
          # reproduce a turn cannot compare two of them.
          "seed" => :seed,
        }.freeze,
      }.freeze,
    }.freeze

    EMPTY_LANE = { arguments: {}.freeze, options: {}.freeze }.freeze

    Result = Data.define(:arguments, :options, :refusal) do
      def self.accepted(arguments:, options:)
        new(arguments: arguments, options: options, refusal: nil)
      end

      def self.refused(refusal) = new(arguments: nil, options: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    REFUSAL = :uncarriable_generation_parameter
    # A tier the row never declared: refused before IO under its own name
    # (codex-rs openai_models.rs service_tier_for_request sends only a
    # model-supported, non-default tier).
    SERVICE_TIER_REFUSAL = :unsupported_service_tier
    SERVICE_TIER_WIRE_KEY = :service_tier
    # The tier codex omits from the wire: the provider's own default.
    DEFAULT_SERVICE_TIER = "default".freeze

    # `reasoning_effort` is the gem's normalized control, lowered further
    # inside each protocol, so this asks the protocol rather than repeating
    # the same word on every lane.
    REASONING_WIRE_KEY = :reasoning_effort
    REASONING_ENABLED_WIRE_KEY = :reasoning_enabled
    # Function tools are not a generation parameter and never enter TABLE:
    # Build lifts `tools` out of `request_options` and hands it over as a
    # declared kwarg. Whether a wire has the kwarg at all is the protocol's
    # own `request_option_keys` — every text_generation protocol declares it,
    # no image/speech/embedding protocol does — and that is the fact the
    # catalog's `tool_calls` default reads.
    TOOLS_WIRE_KEY = :tools
    # Structured output rides the same declared kwarg on every text wire;
    # a speech or image protocol declares `response_format` too, for its
    # CONTAINER, which is why the predicate below asks the workload first.
    OUTPUT_FORMAT_WIRE_KEY = :response_format
    # The kinds each carrying wire lowers, restating the protocol's own
    # inventory: the Messages protocol maps json_schema onto
    # `output_config.format` and raises on text/json_object; the Responses
    # family and both chat dialects carry the full union as `text.format`
    # / `response_format`; Gemini maps json_object and json_schema into
    # `generationConfig` and adds nothing for text. There is NO default:
    # a plain turn sends nothing on every lane.
    ALLOWED_OUTPUT_FORMATS = {
      "anthropic_messages" => %w[json_schema].freeze,
      "openai_responses" => %w[text json_object json_schema].freeze,
      "codex_responses" => %w[text json_object json_schema].freeze,
      "deepseek_responses" => %w[text json_object json_schema].freeze,
      "xai_responses" => %w[text json_object json_schema].freeze,
      "gemini_generate_content" => %w[json_object json_schema].freeze,
      "openai_compatible_chat" => %w[text json_object json_schema].freeze,
      "openrouter_chat" => %w[text json_object json_schema].freeze,
    }.freeze
    # Explicit `cache_control` breakpoints are ONE wire's feature; every
    # other family caches implicitly on prefix stability and the kernel
    # marks nothing there.
    CACHE_BREAKPOINT_FORMATS = %w[anthropic_messages].freeze
    # A prompt cache KEY is two wires' feature: OpenAI routes its prefix
    # cache by `prompt_cache_key` on the Responses and the codex lanes
    # (codex-rs client.rs, opencode transform.ts promptCacheKey). The
    # compatible dialect stays out until a provider is known to honour
    # it (opencode gates by package); no other family keys.
    CACHE_KEY_FORMATS = %w[openai_responses codex_responses].freeze
    # A wire streams when its protocol has a streaming parser — the public
    # entry point every SSE protocol defines and no unary one does.
    STREAMING_ENTRY_POINT = :stream

    class << self
      # `extra_body` is never produced here: a caller-supplied semantic
      # control may not become a verbatim wire field.
      def lower(adapter_profile:, generation_config:)
        lane = TABLE.fetch(adapter_profile, EMPTY_LANE)
        arguments = lane.fetch(:arguments)
        options = lane.fetch(:options)
        # The config renders its own values (an OutputFormat knows its request
        # form); this layer renames and nothing else, so value rendering keeps
        # exactly one authority.
        values = generation_config.request_options

        uncarriable = values.keys.map(&:to_s) - arguments.keys - options.keys
        return Result.refused(REFUSAL) if uncarriable.any?

        Result.accepted(
          arguments: lowered(values, arguments),
          options: lowered(values, options)
        )
      end

      # The resolver already chose the model's enabled state and effort.
      # The gem owns their wire spelling and suppresses effort when disabled;
      # replay context rides only while reasoning remains enabled.
      def lower_reasoning(adapter_profile:, effort:, enabled: nil, context: nil)
        options = { REASONING_WIRE_KEY => effort, REASONING_ENABLED_WIRE_KEY => enabled }.compact
        return Result.accepted(arguments: {}.freeze, options: {}.freeze) if options.empty?
        unless (options.keys - declared_wire_keys(adapter_profile)).empty?
          return Result.refused(REFUSAL)
        end

        if context && enabled != false && effort != "none" && reasoning_contexts(adapter_profile).include?(context)
          options = options.merge(reasoning: { context: context })
        end
        Result.accepted(arguments: {}.freeze, options: options.freeze)
      end

      def reasoning_contexts(adapter_profile)
        Array(SimpleInference::ApiFormat.defaults(adapter_profile).dig(:reasoning_options, "contexts"))
      end

      # CODEX'S RULE, VERBATIM: nothing rides for an absent or `default`
      # tier; a declared tier lowers onto the row's wire key; an
      # undeclared one is refused rather than guessed at. `service_tiers`
      # is the profile's declared list — the row's own fact.
      def lower_service_tier(adapter_profile:, tier:, service_tiers:)
        none = Result.accepted(arguments: {}.freeze, options: {}.freeze)
        return none if tier.nil? || tier.to_s == DEFAULT_SERVICE_TIER

        wire_key = TABLE.dig(adapter_profile, :options, "service_tier")
        return Result.refused(REFUSAL) if wire_key.nil?
        return Result.refused(SERVICE_TIER_REFUSAL) unless Array(service_tiers).include?(tier.to_s)

        Result.accepted(arguments: {}.freeze, options: { wire_key => tier.to_s }.freeze)
      end

      # PROMPT CACHE KEYS ARE A WIRE'S PROPERTY: the one fact behind
      # Build's routing key.
      def carries_cache_key?(adapter_profile)
        CACHE_KEY_FORMATS.include?(adapter_profile)
      end

      # FUNCTION TOOLS ARE A WIRE'S PROPERTY: does this lane's protocol
      # accept `tools` by name? The one fact behind the catalog's default.
      def carries_function_tools?(adapter_profile)
        declared_wire_keys(adapter_profile).include?(TOOLS_WIRE_KEY)
      end

      # STRUCTURED OUTPUT IS A WIRE'S PROPERTY: a text lane whose protocol
      # declares the wire key offers `output_format`, and the catalog
      # synthesizes the descriptor for a row silent on it.
      def carries_output_format?(adapter_profile)
        SimpleInference::ApiFormat.workload(adapter_profile) == "text_generation" &&
          declared_wire_keys(adapter_profile).include?(OUTPUT_FORMAT_WIRE_KEY)
      end

      def allowed_output_formats(adapter_profile)
        ALLOWED_OUTPUT_FORMATS.fetch(adapter_profile)
      end

      # PROMPT CACHING IS EVERY TEXT WIRE'S PROPERTY: the provider caches a
      # stable prefix on every text lane — Anthropic through the
      # kernel-placed breakpoints, the rest implicitly — and no other
      # workload has a prompt to cache. The one fact behind the catalog's
      # `prompt_caching` default; `false` on a row is the opt-out.
      def carries_prompt_caching?(adapter_profile)
        SimpleInference::ApiFormat.workload(adapter_profile) == "text_generation"
      end

      # CACHE BREAKPOINTS ARE ONE WIRE'S PROPERTY: the narrower fact behind
      # Build's marker placement, never the capability's derivation.
      def carries_cache_breakpoints?(adapter_profile)
        CACHE_BREAKPOINT_FORMATS.include?(adapter_profile)
      end

      # WHETHER A PROFILE'S REQUESTS CARRY EXPLICIT BREAKPOINTS: the wire's
      # property, gated by the row's `prompt_caching` — every text wire's
      # default, `false` the one opt-out (`ModelCatalog::ProfileBuilder`).
      # The capability alone never places a marker: a Responses row has
      # prompt caching on and nothing to mark, so a mis-declaration cannot
      # rewrite a system prompt on a wire that never reads the marker. The
      # one predicate Build places by, and the text benches with it.
      def explicit_cache_breakpoints?(profile)
        profile.capability_enabled?("prompt_caching") && carries_cache_breakpoints?(profile.adapter_profile)
      end

      # STREAMING IS A WIRE'S PROPERTY: the protocol either parses a
      # stream or answers one body.
      def carries_streaming?(adapter_profile)
        SimpleInference::ApiFormat::PROTOCOL_CLASSES
          .fetch(adapter_profile).public_method_defined?(STREAMING_ENTRY_POINT)
      end

      # Straight from the gem, the authority on what may be passed by name;
      # the contract test checks the lowering table against it.
      def declared_wire_keys(adapter_profile)
        SimpleInference::ApiFormat::PROTOCOL_CLASSES
          .fetch(adapter_profile).request_option_keys
      end

      private

        def lowered(values, mapping)
          values
            .select { |name, _| mapping.key?(name.to_s) }
            .to_h { |name, value| [mapping.fetch(name.to_s), value] }
            .freeze
        end
    end
  end
end
