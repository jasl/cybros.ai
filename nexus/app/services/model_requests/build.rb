module ModelRequests
  # The request, built immediately before IO as the CompiledRequest dispatch
  # consumes — never serialized or fingerprinted. The gem's validators run
  # here, before the claim, so an invalid request terminalizes without spending an ordinal.
  class Build
    # Missing or unsealed request data cannot be sent to a provider.
    MISSING_INPUT = :accepted_input_unavailable
    # A preparation failure after acceptance terminalizes with typed
    # evidence, never a dropped media or a placeholder.
    MEDIA_UNUSABLE = :input_media_unusable
    # The prepared bytes exceed what one request part may inline. Distinct
    # from `content_too_large`, which is a JSON body's bound: binary and
    # base64 expansion are never charged to that one.
    OVER_INLINE_BOUND = :input_media_too_large
    UNKNOWN_PROFILE = :execution_profile_unknown
    # The model does not offer what the request asks for. `CapabilityError`
    # is not a `ValidationError` in the gem; deterministic, therefore terminal.
    CAPABILITY_UNAVAILABLE = :model_capability_unavailable
    # The gem's validator refused the assembled arguments. Deterministic
    # against immutable input, so terminal.
    INVALID_REQUEST = :request_invalid
    # A lane whose lowering table names a required argument this input did
    # not produce (speech's `voice` today).
    MISSING_ARGUMENT = :required_argument_missing

    TEXT_PART = "input_text".freeze
    IMAGE_PART = "input_image".freeze
    FILE_PART = "input_file".freeze

    # Wire facts that ride `request_options` for storage but are never
    # generation controls: lifted out before the lowering table, which would
    # rightly refuse them, and handed over as declared kwargs.
    RESERVED_REQUEST_FACTS = %w[tools tool_choice instructions].freeze
    # The requested service tier rides `request_options` the same way (a
    # per-request control, never a catalog generation parameter) and is
    # lowered under codex's rule rather than handed over verbatim.
    SERVICE_TIER_FACT = "service_tier".freeze
    # The request's cache kind rides the same bag, read by the placement
    # alone (Nexus::PromptCache::RequestKind).
    PROMPT_CACHE_FACT = Nexus::PromptCache::RequestKind::FACT

    Result = Data.define(:request, :refusal) do
      def self.built(request) = new(request: request, refusal: nil)
      def self.refused(refusal) = new(request: nil, refusal: refusal)

      def built? = refusal.nil?
    end

    def self.call(...) = new(...).call

    # `reasoning_context` is the row's own `default_context` (which earlier
    # turns' reasoning a Responses service renders), read from the catalog
    # at the send like every other wire fact; nil lowers none.
    def initialize(invocation:, profile:, base_url:, host:, reasoning_context: nil)
      @invocation = invocation
      @profile = profile
      @base_url = base_url
      @host = host
      @reasoning_context = reasoning_context
    end

    def call
      source = InputSource.accepted_body(@invocation)
      return Result.refused(MISSING_INPUT) unless source&.sealed?

      build(source)
    rescue SimpleInference::ConfigurationError
      Result.refused(UNKNOWN_PROFILE)
    end

    private

      def build(source)
        input = InputSource.request_input(
          invocation: @invocation, source: source, profile: profile
        )
        uploads = source.request_uploads(input.workload)

        media = resolved_media(uploads)
        return Result.refused(MEDIA_UNUSABLE) if media.nil?
        return Result.refused(OVER_INLINE_BOUND) if oversize_inlined?(media)

        reserved = reserved_request_facts
        lowered = WireLowering.lower(
          adapter_profile: input.adapter_profile, generation_config: input.generation_config
        )
        return Result.refused(lowered.refusal) unless lowered.accepted?

        reasoning = WireLowering.lower_reasoning(
          adapter_profile: input.adapter_profile, effort: input.reasoning_effort,
          enabled: input.reasoning_enabled, context: @reasoning_context
        )
        return Result.refused(reasoning.refusal) unless reasoning.accepted?

        tier = WireLowering.lower_service_tier(
          adapter_profile: input.adapter_profile, tier: requested_service_tier,
          service_tiers: profile.service_tiers
        )
        return Result.refused(tier.refusal) unless tier.accepted?

        options = lowered.options.merge(reasoning.options).merge(tier.options).merge(reserved)
        return Result.refused(ModelSelection::Workloads::TOO_MANY_INPUT_TEXTS) if singular_overflow?(input)
        return Result.refused(MISSING_ARGUMENT) if missing_arguments?(input, lowered.arguments)

        Result.built(request_for(input, uploads, media, lowered.arguments, options))
      rescue SimpleInference::ConfigurationError
        # Its own class first: `ConfigurationError` IS a `ValidationError` in
        # the gem, and the arm below would report a retired lane as an invalid
        # request — the same fact under the wrong name.
        Result.refused(UNKNOWN_PROFILE)
      rescue SimpleInference::CapabilityError
        Result.refused(CAPABILITY_UNAVAILABLE)
      rescue SimpleInference::ValidationError
        Result.refused(INVALID_REQUEST)
      end

      # Deep-symbolized: the vendored protocols read symbol keys only, and a
      # string-keyed tool lost its name on the Anthropic and Gemini wires.
      # This is the vendored-gem boundary — the one key-shape conversion:
      # the row's stored request facts cross into `SimpleInference` here and
      # nowhere else, so this is the only `deep_symbolize_keys` in app/.
      def reserved_request_facts
        return {} unless @invocation.workload == "text_generation"

        facts = @invocation.request_options.slice(*RESERVED_REQUEST_FACTS)
        facts.to_h do |key, value|
          normalized = case value
          when Array then value.map { |entry| symbolize_fact(entry) }
          else symbolize_fact(value)
          end
          [key.to_sym, normalized]
        end
      end

      def symbolize_fact(value)
        entry = Hash.try_convert(value)
        entry ? entry.deep_symbolize_keys : value
      end

      # Absent by default, never a default of ours: only a caller that
      # stored a tier on the invocation asks for one.
      def requested_service_tier
        return nil unless @invocation.workload == "text_generation"

        @invocation.request_options[SERVICE_TIER_FACT]
      end

      # No wider than the one call that can raise for these reasons, or a
      # retired lane reports as unusable media. A vanished blob is a
      # preparation failure with typed evidence.
      def resolved_media(uploads)
        UploadMedia.by_public_id(
          uploads, input_media: profile.input_media, streamed: profile.multipart?
        )
      rescue SimpleInference::ValidationError, ActiveStorage::FileNotFoundError,
             ActiveStorage::UnrepresentableError, UploadMedia::Unpreparable => error
        # The one word the caller answers folds four causes; the class is
        # what a world log needs to tell them apart.
        Rails.logger.info(
          "event=input_media_unusable invocation=#{@invocation.public_id} error_class=#{error.class}"
        )
        nil
      end

      # Checked after preparation, on the bytes that will be inlined:
      # re-encoding can inflate, so an upload under its own bound can come back over this one.
      def oversize_inlined?(media)
        return false if profile.multipart?

        media.each_value.any? do |input|
          !Nexus::SizeBounds.bytes_within?(:inline_binary_bound, input.byte_size)
        end
      end

      # ---- the per-workload resource arguments ------------------------------

      def request_for(input, uploads, media, arguments, options)
        case input.workload
        when "text_generation" then responses(input, uploads, media, options)
        when "image_generation" then images(input, uploads, media, options)
        when "speech_generation" then speech(input, arguments, options)
        when "transcription" then transcription(input, uploads, media, options)
        when "embedding" then embeddings(input, options)
        else raise ArgumentError, "unmapped workload #{input.workload}"
        end
      end

      def responses(input, uploads, media, options)
        streaming = streaming?(input)
        wire_input, validated = SimpleInference::Planning::RequestValidator.validate_responses_request(
          profile: profile, model: input.wire_model,
          input: responses_items(input.input, uploads.index_by(&:public_id), media),
          options: options.merge(cache_key(input)),
          streaming: streaming
        )
        # Model prompt formats project this send's roles without rewriting the
        # sealed source. Place cache markers on that projection, and retain its
        # options: reusing the originals could add absorbed instructions twice.
        placement = place_cache_breakpoints(wire_input, validated)
        client(streaming: streaming).responses.compile_from_validated(
          model: input.wire_model, input: placement.input, stream: streaming,
          **validated.merge(cache_instructions(placement))
        )
      end

      # Bound uploads make the call an EDIT: they ride the gem's `images:` in
      # sealed occurrence order as the same prepared bytes-only media the Responses
      # lanes inline, and the protocol's declared encoding spells the body.
      # No upload, no edit. The kernel binds no mask slot.
      def images(input, uploads, media, options)
        options = options.merge(images: uploads.map { |upload| media.fetch(upload.public_id) }) if uploads.any?
        validated = SimpleInference::Planning::RequestValidator.validate_images_request(
          profile: profile, model: input.wire_model, options: options
        )
        client(streaming: false).images.compile_from_validated(
          model: input.wire_model, prompt: input.input, **validated
        )
      end

      # `voice` is this seam's required ARGUMENT rather than one of its
      # options, which is why the lowering table splits the two.
      def speech(input, arguments, options)
        validated = SimpleInference::Planning::RequestValidator.validate_speech_request(
          profile: profile, model: input.wire_model, options: options
        )
        client(streaming: false).audio.speech.compile_from_validated(
          model: input.wire_model, input: input.input,
          voice: arguments.fetch(:voice), **validated
        )
      end

      # The multipart lane: the audio rides the gem's file descriptor, and
      # the optional text is the provider's `prompt` hint acceptance took.
      def transcription(input, uploads, media, options)
        options = options.merge(prompt: input.input) unless input.input.nil?
        validated = SimpleInference::Planning::RequestValidator.validate_transcription_request(
          profile: profile, model: input.wire_model, options: options
        )
        upload = uploads.sole
        prepared_media = media.fetch(upload.public_id)
        client(streaming: false).audio.transcriptions.compile_from_validated(
          model: input.wire_model,
          media: prepared_media,
          filename: upload.filename,
          **validated
        )
      end

      def embeddings(input, options)
        validated = SimpleInference::Planning::RequestValidator.validate_embeddings_request(
          profile: profile, model: input.wire_model, options: options
        )
        client(streaming: false).embeddings.compile_from_validated(
          model: input.wire_model,
          input: singular?(input) ? input.input.sole : input.input,
          **validated
        )
      end

      # Placement runs last, over the final material, or a marker sits at a
      # boundary the wire never sees. The tail rides under replayed
      # reasoning as under any other history: the provider keeps prior-turn
      # thinking in the cached prefix, so the gate that once skipped it
      # turned the history cache off on exactly the loops where it pays.
      # The tier and the tail are the request's KIND, stamped where it was
      # minted (Nexus::PromptCache::RequestKind) — never `@host` (the
      # endpoint); a request of a kind that writes no marker is not marked.
      def place_cache_breakpoints(wire_input, options)
        kind = request_kind
        placement = Nexus::PromptCache::Breakpoints.apply(
          instructions: options[:instructions],
          input: wire_input,
          capable: kind.marked? && WireLowering.explicit_cache_breakpoints?(profile),
          tier: kind.tier,
          tail: kind.tail
        )
        log_placement(placement, kind)
        placement
      end

      def request_kind = Nexus::PromptCache::RequestKind.of(@invocation.request_options)

      def cache_instructions(placement)
        placement.instructions.nil? ? {} : { instructions: placement.instructions }
      end

      # THE KEY BY THE TURN'S HOST (codex-rs client.rs prompt_cache_key —
      # a parent and its children share routing): the invocation's own
      # derivation (`prompt_cache_key`), on the two wires that route by
      # it. Never the invocation id, which would defeat routing; a InferenceRequest
      # sends none.
      def cache_key(input)
        return {} unless WireLowering.carries_cache_key?(input.adapter_profile)

        key = @invocation.prompt_cache_key
        key.nil? ? {} : { prompt_cache_key: key }
      end

      # The seam logs from the ONE computation, never by re-deriving the
      # predicates — the evidence line can then never disagree with what
      # was placed. Quiet on the common non-caching path.
      def log_placement(placement, kind)
        return unless placement.capable

        Rails.logger.info(
          "event=prompt_cache_placement invocation=#{@invocation.public_id} " \
          "provider=#{@invocation.provider_id} model=#{@invocation.model_ref} kind=#{kind.kind} " \
          "enabled=#{placement.enabled} tail=#{placement.tail} tier=#{placement.tier}"
        )
      end

      # ---- input shaping ----------------------------------------------------

      # A plain-string prompt becomes one user message: every lane accepts
      # an item list, only some a naked string.
      def responses_items(value, uploads, media)
        case value
        when Array then value.filter_map { |element| responses_element(element, uploads, media) }
        else [{ "role" => "user", "content" => [text_part(value)] }]
        end
      end

      # The protocols place and stitch role-less items; inherited native
      # reasoning first follows the current target's replay boundary.
      def responses_element(element, uploads, media)
        case element
        when Nexus::ToolCallInputItem
          tool_call_payload(element)
        when Nexus::ReasoningInputItem
          reasoning_payload(element)
        when Nexus::ToolResultInputItem
          element.payload
        else responses_item(element, uploads, media)
        end
      end

      # A later model may inherit a sealed prefix containing another model's
      # signed call. Keep the neutral pair; native material belongs to its origin.
      def tool_call_payload(item)
        origin = item.native_origin
        return item.payload if origin.nil?

        native_origin_matches?(origin) ? item.payload : item.payload.except("provider_payload")
      end

      def native_origin_matches?(origin, require_same_model: true)
        origin["api_format"] == profile.adapter_profile &&
          ModelReasoning::ReplayLadder.origin_miss(origin: origin, provider_id: profile.provider_id,
            model_id: profile.model_pin, reasoning_enabled: @invocation.reasoning_enabled,
            require_same_model: require_same_model).nil?
      end

      # Native reasoning inside a sealed prefix meets the ladder's own rule
      # for its origin's format (ReplayLadder.same_model?): read by this
      # target, or nothing — never a portable rendering of another model's.
      def reasoning_payload(item)
        origin = item.native_origin
        return item.payload if origin.nil?

        format = ModelReasoning::TraceBuilder::ORIGIN_FORMAT_VARIANTS[origin["api_format"]]
        item.payload if native_origin_matches?(origin,
          require_same_model: ModelReasoning::ReplayLadder.same_model?(format))
      end

      # An assistant message's `phase` is a word of one wire grammar, so it
      # rides only to the wire AND the lane that wrote it — a later model on
      # that lane keeps it, every other wire drops it silently (the message
      # is still the message). It is appended after the content, and only to
      # a message that carries one, so no other message's bytes move. The
      # chat wire's reasoning is a field of the message beside its content
      # (Nexus::ReasoningInputPart::CHAT_FIELDS), never a content part; a message that holds
      # only that field carries no content key, and a round's calls fold
      # onto it.
      def responses_item(message, uploads, media)
        lifted, rest = message.parts.partition { |part| chat_reasoning?(part) }
        parts = rest.filter_map { |part| responses_part(part, uploads, media) }
        fields = lifted.filter_map { |part| reasoning_payload(part) }.to_h { |payload| chat_reasoning_field(payload) }
        return nil if parts.empty? && fields.empty?

        item = parts.any? ? { "role" => message.role, "content" => parts } : { "role" => message.role }
        item = item.merge(fields)
        message.phase && phase_lane?(message.native_origin) ? item.merge("phase" => message.phase) : item
      end

      def chat_reasoning?(part)
        part.type == Nexus::InputParts::REASONING && Nexus::ReasoningInputPart::CHAT_FIELDS.key?(part.payload["type"])
      end

      def chat_reasoning_field(payload)
        type = payload.fetch("type")
        [type, payload.fetch(Nexus::ReasoningInputPart::CHAT_FIELDS.fetch(type))]
      end

      def phase_lane?(origin)
        origin.present? && origin["api_format"] == profile.adapter_profile &&
          origin["provider_id"] == profile.provider_id
      end

      def responses_part(part, uploads, media)
        case part.type
        when Nexus::InputParts::UPLOAD
          prepared = media.fetch(part.upload_public_id)
          if prepared.media_type == "application/pdf"
            { "type" => FILE_PART, "filename" => uploads.fetch(part.upload_public_id).filename.to_s,
              "file_data" => prepared }
          else
            { "type" => IMAGE_PART, "image_url" => prepared }
          end
        when Nexus::InputParts::REASONING
          # The neutral block shape (thinking / redacted_thinking / thought)
          # the protocol lowers natively.
          reasoning_payload(part)
        else text_part(part.text)
        end
      end

      def text_part(text) = { "type" => TEXT_PART, "text" => text }

      # A `stream_only` lane's wire accepts ONLY streaming requests, so the
      # lane's own truth raises a flag the caller left down. It never lowers
      # one the caller raised.
      def streaming?(input) = input.stream || profile.streams?

      # WHATEVER the lane declares, not only one. Acceptance already refuses
      # against the declared number, so a seam that only knew how to enforce
      # `1` would silently pass a batch of three on a lane that declared two.
      def singular_overflow?(input)
        bound = arity_of(input)
        !bound.nil? && input.input.length > bound
      end

      def singular?(input) = arity_of(input) == 1

      def arity_of(input)
        return unless input.workload == "embedding"

        SimpleInference::ApiFormat.max_input_texts(profile.adapter_profile)
      end

      # Only speech takes a required argument by name today; the lowering
      # table is the authority on which, and this asks it rather than
      # repeating the word.
      def missing_arguments?(input, arguments)
        required = WireLowering::TABLE.dig(input.adapter_profile, :arguments).to_h.values
        (required - arguments.keys).any?
      end

      # Compile uses the real profile/endpoint/host composition but no
      # credential. Compiling cannot touch the adapter; the claimed send later
      # supplies the credential and executes this exact value on its client.
      def client(streaming:)
        @client ||= ModelCatalog::AssembleClient.call(
          profile: profile, base_url: @base_url, credential: nil,
          host: @host, streaming: streaming, invocation: @invocation
        )
      end

      attr_reader :profile
  end
end
