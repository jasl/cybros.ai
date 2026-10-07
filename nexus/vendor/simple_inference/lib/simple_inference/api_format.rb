module SimpleInference
  # WHAT AN API FORMAT IS — the facts that follow from the wire itself, so a
  # consumer naming a format inherits them instead of restating them.
  #
  # THIS FILE EXISTS BECAUSE ITS PREDECESSOR DID NOT. Until 2026-08-21 this
  # gem shipped a `PROFILES` list: 33 rows carrying the model names, their
  # context windows, their prices and their timeouts. Measured before it was
  # removed, the 26 production rows disagreed on NOTHING within one format
  # for credentials, limits, generation parameters, service tiers,
  # capabilities or reasoning — and 14 of them differed from a sibling by the
  # MODEL NAME ALONE. A gem cannot hold that list: a deployment adds a model
  # by editing configuration, never by releasing a library, and prices and
  # model lists change faster than any library ships.
  #
  # So the split is: this gem says what a WIRE is, and the consumer says
  # which models exist, what they cost, and how long they may run. Everything
  # here is a DEFAULT — a consumer composing an ExecutionProfile overrides
  # any of it, which is what makes the timeouts and bounds settable from
  # outside as a library's should be.
  module ApiFormat
    # An explicit closed map from the format vocabulary to a protocol class.
    # A format absent here has no conforming implementation and fails closed
    # in protocol_for; the map covers the complete vocabulary.
    PROTOCOL_CLASSES = {
      "openai_responses" => Protocols::OpenAIResponses,
      "codex_responses" => Protocols::CodexResponses,
      "anthropic_messages" => Protocols::AnthropicMessages,
      "gemini_generate_content" => Protocols::GeminiGenerateContent,
      "openrouter_chat" => Protocols::OpenRouterResponses,
      # The plain OpenAI-compatible translator: a third-party host speaking
      # the OpenAI-compatible chat dialect names this format, and it is the
      # case this whole file exists for — nobody can ship a row for a model
      # only one deployment runs.
      "openai_compatible_chat" => Protocols::OpenAICompatibleResponses,
      "deepseek_responses" => Protocols::DeepSeekResponses,
      "xai_responses" => Protocols::XAIResponses,
      "openai_images" => Protocols::OpenAIImages,
      "openai_audio_speech" => Protocols::OpenAIAudioSpeech,
      "openai_audio_transcriptions" => Protocols::OpenAIAudioTranscriptions,
      "openai_embeddings" => Protocols::OpenAIEmbeddings,
      "gemini_embeddings" => Protocols::GeminiEmbeddings,
    }.freeze

    # The wall-clock backstop per WORKLOAD, not per format — it answers "how
    # long may one call hang", which is a property of the kind of work, and
    # every consumer may override it per model. Generous on purpose: this is
    # not a service promise, it is the point past which a hung call stops
    # costing money.
    WORKLOAD_DEADLINE_SECONDS = {
      "text_generation" => 3600,
      "image_generation" => 1800,
      "transcription" => 1800,
      "speech_generation" => 900,
      "embedding" => 300,
    }.freeze

    # The conservative context window a model gets when it declares none. A
    # model nobody has measured is never assumed to be larger than it is.
    DEFAULT_INPUT_TOKENS = 128_000

    # WHICH KIND OF WORK THIS WIRE DOES. An endpoint that generates images
    # is not a text endpoint, so naming the format names the workload too —
    # which is why a catalog entry declares neither a workload nor a profile
    # id, only the format its provider speaks.
    WORKLOADS = {
      "anthropic_messages" => "text_generation",
      "openai_compatible_chat" => "text_generation",
      "codex_responses" => "text_generation",
      "deepseek_responses" => "text_generation",
      "gemini_embeddings" => "embedding",
      "gemini_generate_content" => "text_generation",
      "openai_audio_speech" => "speech_generation",
      "openai_audio_transcriptions" => "transcription",
      "openai_embeddings" => "embedding",
      "openai_images" => "image_generation",
      "openai_responses" => "text_generation",
      "openrouter_chat" => "text_generation",
      "xai_responses" => "text_generation",
    }.freeze

    # The two execution shapes every wire falls into, named once: a streaming
    # lane may run on either closed pair; a unary lane runs on the queue
    # pair only. Each format merges the rest of its facts over
    # the lane it belongs to.
    STREAMING_LANE = {
      primary_execution_pair: ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR,
      allowed_execution_pairs: ExecutionProfile::EXECUTION_PAIRS,
      stream_idle_timeout_seconds: ExecutionProfile::DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS,
      capabilities: %w[streaming].freeze,
    }.freeze
    UNARY_LANE = {
      primary_execution_pair: ExecutionProfile::SOLID_QUEUE_HTTPX_PAIR,
      allowed_execution_pairs: [ExecutionProfile::SOLID_QUEUE_HTTPX_PAIR].freeze,
      stream_idle_timeout_seconds: ExecutionProfile::DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS,
      capabilities: [].freeze,
    }.freeze

    # Inline PDF contracts belong to the four public formats adapted here,
    # not to every subclass sharing their implementation. Wire references:
    # https://developers.openai.com/api/docs/guides/file-inputs
    # https://platform.claude.com/docs/en/build-with-claude/pdf-support
    # https://ai.google.dev/gemini-api/docs/generate-content/document-processing
    # Files remain whole bytes; no fixed per-document token cost is known.
    DEFAULTS = {
      "anthropic_messages" => {
        protocol_route: "messages_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: {
          "kind" => "anchored",
          "encoding" => "o200k_base",
          "safety_factor" => "2.5",
        }.freeze,
        reasoning_options: {
          "efforts" => %w[low medium high xhigh max].freeze,
          "modes" => %w[adaptive].freeze,
          "summaries" => %w[summarized omitted].freeze,
          "budgets" => %w[manual_mode_only].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/jpeg image/png image/gif image/webp].freeze,
            "max_dimension" => 1568,
            "token_cost" => 3279,
          }.freeze,
          "file" => {
            "mime_allowlist" => %w[application/pdf].freeze,
          }.freeze,
        }.freeze,
        wire_options: {
          messages_path: "/v1/messages",
          anthropic_version: "2023-06-01",
        }.freeze,
      }.freeze,
      "codex_responses" => {
        protocol_route: "responses_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {
          "efforts" => %w[low medium high xhigh max].freeze,
          "contexts" => %w[all_turns].freeze,
          "summaries" => %w[none auto concise detailed].freeze,
          "budgets" => %w[none].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        # Codex prepares PNG, JPEG and WebP prompt images. This is our
        # resize bound (codex-rs utils/image MAX_DIMENSION), not a provider
        # rejection limit or a declaration of image token accounting.
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp].freeze,
            "max_dimension" => 2048,
          }.freeze,
        }.freeze,
        wire_options: {
          responses_path: "/responses",
          use_responses_lite: true,
          stream_only: true,
          originator: "codex_cli_rs",
          responses_lite_header: "x-openai-internal-codex-responses-lite",
          default_store: false,
          encrypted_reasoning_include: true,
        }.freeze,
      }.freeze,
      "deepseek_responses" => {
        protocol_route: "responses_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: nil,
        reasoning_options: {
          "efforts" => %w[none minimal low medium high xhigh max].freeze,
          "budgets" => %w[none].freeze,
          "default_enabled" => %w[true].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        input_media: {},
        wire_options: {
          responses_path: "/responses",
        }.freeze,
      }.freeze,
      "gemini_embeddings" => {
        protocol_route: "embed_content_http",
        **UNARY_LANE,
        output_modalities: %w[embedding].freeze,
        token_counter: {
          "kind" => "anchored",
          "encoding" => "o200k_base",
          "safety_factor" => "2.5",
        }.freeze,
        reasoning_options: {},
        generation_parameters: {},
        service_tiers: [],
        input_media: {},
        wire_options: {},
      }.freeze,
      "gemini_generate_content" => {
        protocol_route: "generate_content_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: {
          "kind" => "anchored",
          "encoding" => "o200k_base",
          "safety_factor" => "2.5",
        }.freeze,
        reasoning_options: {
          "efforts" => %w[minimal low medium high].freeze,
          "budgets" => %w[none].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp image/heic image/heif].freeze,
            "max_dimension" => 384,
            "token_cost" => 258,
          }.freeze,
          "file" => {
            "mime_allowlist" => %w[application/pdf].freeze,
          }.freeze,
        }.freeze,
        wire_options: {},
      }.freeze,
      "openai_audio_speech" => {
        protocol_route: "audio_speech_http",
        **UNARY_LANE,
        output_modalities: %w[audio].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {},
        generation_parameters: {
          "voice" => {
            "kind" => "string",
            "default" => "alloy",
            "minimum" => nil,
            "maximum" => nil,
            "allowed_values" => %w[alloy].freeze,
          }.freeze,
        }.freeze,
        service_tiers: [],
        input_media: {},
        wire_options: {
          speech_path: "/v1/audio/speech",
        }.freeze,
      }.freeze,
      "openai_audio_transcriptions" => {
        protocol_route: "audio_transcriptions_http_multipart",
        **UNARY_LANE,
        output_modalities: %w[text].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {},
        generation_parameters: {},
        service_tiers: [],
        input_media: {
          "audio" => {
            "mime_allowlist" => %w[audio/flac audio/mpeg audio/mp4 audio/ogg audio/wav audio/webm].freeze,
          }.freeze,
        }.freeze,
        wire_options: {
          transcriptions_path: "/v1/audio/transcriptions",
        }.freeze,
      }.freeze,
      "openai_embeddings" => {
        protocol_route: "embeddings_http",
        **UNARY_LANE,
        output_modalities: %w[embedding].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {},
        generation_parameters: {},
        service_tiers: [],
        input_media: {},
        wire_options: {
          embeddings_path: "/v1/embeddings",
        }.freeze,
      }.freeze,
      "openai_images" => {
        protocol_route: "images_generations_http",
        **UNARY_LANE,
        output_modalities: %w[image].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {},
        generation_parameters: {},
        service_tiers: [],
        # THE WIRE TAKES AN IMAGE IN on its edits route (v1/images/edits:
        # png/webp/jpg, up to 16 `image[]` parts for the gpt-image family)
        # — whether a MODEL does is the row's `input_modalities`, and a row
        # silent on it takes none. No `max_dimension`: an edit's source is
        # sent as it is, never re-encoded, so the inline byte bound is the
        # only cap; no token cost is declared for an image-priced route.
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp].freeze,
          }.freeze,
        }.freeze,
        # The edits ENCODING is a lane fact: the public route is multipart;
        # the codex backend row declares `json` (codex-rs ImageEditRequest)
        # and its `originator` marker. Plain rows declare neither.
        wire_options: {
          images_path: "/v1/images/generations",
          images_edits_path: "/v1/images/edits",
          images_edits_encoding: "multipart",
        }.freeze,
      }.freeze,
      "openai_responses" => {
        protocol_route: "responses_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: {
          "kind" => "tiktoken",
          "encoding" => "o200k_base",
        }.freeze,
        reasoning_options: {
          "efforts" => %w[none minimal low medium high xhigh max].freeze,
          "modes" => %w[standard pro].freeze,
          "contexts" => %w[auto current_turn all_turns].freeze,
          "summaries" => %w[auto concise detailed].freeze,
          "budgets" => %w[none].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp image/gif].freeze,
            "max_dimension" => 1600,
            "token_cost" => 2500,
          }.freeze,
          "file" => {
            "mime_allowlist" => %w[application/pdf].freeze,
          }.freeze,
        }.freeze,
        wire_options: {
          responses_path: "/v1/responses",
        }.freeze,
      }.freeze,
      # THE FORMAT WITH NO SHIPPED ROW, and the reason this table exists at
      # all: a third-party host speaking the OpenAI chat dialect becomes a
      # catalog entry, not a library release. Its defaults are the dialect's
      # own — the broker extensions OpenRouter adds are the broker's, not the
      # dialect's, so none of them are here.
      "openai_compatible_chat" => {
        protocol_route: "chat_completions_http_sse",
        **STREAMING_LANE,
        # THE CHAT DIALECT CARRIES IMAGES, whoever is hosting it: an
        # `image_url` content part is part of the dialect, and a vision model
        # on a self-hosted server is an ordinary deployment. The shipped rows
        # this table was measured from happened to declare no image input,
        # which is a fact about the models we shipped and not about the wire
        # — exactly the confusion this file exists to end.
        #
        # `max_dimension` is OUR cap, the largest image this side will send,
        # and it is ours to choose whatever the host charges. No token cost is
        # declared: a third-party host's accounting is not knowable from here.
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp image/gif].freeze,
            "max_dimension" => 1_600,
          }.freeze,
          "file" => {
            "mime_allowlist" => %w[application/pdf].freeze,
          }.freeze,
        }.freeze,
        output_modalities: %w[text].freeze,
        token_counter: nil,
        # THE DIALECT CARRIES A REASONING EFFORT — `reasoning_effort` is one
        # of the request keys this protocol writes and the stream reads back
        # reasoning deltas — so a reasoning-capable open model on a
        # self-hosted server can say which efforts it takes. The vocabulary
        # is the union the OpenAI-compatible ecosystem uses; a model narrows
        # it to the ones it really has.
        reasoning_options: {
          "efforts" => %w[none minimal low medium high xhigh max].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        wire_options: {}.freeze,
      }.freeze,
      "openrouter_chat" => {
        protocol_route: "chat_completions_http_sse",
        **STREAMING_LANE,
        # THE CHAT DIALECT CARRIES IMAGES, whoever is hosting it: an
        # `image_url` content part is part of the dialect, and a vision model
        # on a self-hosted server is an ordinary deployment. The shipped rows
        # this table was measured from happened to declare no image input,
        # which is a fact about the models we shipped and not about the wire
        # — exactly the confusion this file exists to end.
        #
        # `max_dimension` is OUR cap, the largest image this side will send,
        # and it is ours to choose whatever the host charges. No token cost is
        # declared: a third-party host's accounting is not knowable from here.
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/png image/jpeg image/webp image/gif].freeze,
            "max_dimension" => 1_600,
          }.freeze,
        }.freeze,
        output_modalities: %w[text].freeze,
        token_counter: nil,
        reasoning_options: {
          "efforts" => %w[max xhigh high medium low minimal none].freeze,
          "budgets" => %w[reasoning_max_tokens].freeze,
          # The broker's per-model `reasoning.default_enabled` on
          # `/api/v1/models` goes either way; a row restates it for its id.
          "default_enabled" => %w[true false].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        wire_options: {
          stream_include_usage: false,
        }.freeze,
      }.freeze,
      "xai_responses" => {
        protocol_route: "responses_http_sse",
        **STREAMING_LANE,
        output_modalities: %w[text].freeze,
        token_counter: nil,
        reasoning_options: {
          "efforts" => %w[low medium high xhigh].freeze,
          "budgets" => %w[none].freeze,
        }.freeze,
        generation_parameters: {},
        service_tiers: [],
        input_media: {
          "image" => {
            "mime_allowlist" => %w[image/jpeg image/png].freeze,
            "max_dimension" => 1600,
          }.freeze,
        }.freeze,
        wire_options: {
          responses_path: "/v1/responses",
        }.freeze,
      }.freeze,
    }.freeze

    FORMATS = DEFAULTS.keys.freeze

    class << self
      # The format's declared defaults, frozen. Raises rather than guessing:
      # a format nobody adapted is not a format.
      def defaults(format)
        DEFAULTS.fetch(format.to_s) do
          raise SimpleInference::ConfigurationError,
                "unknown api_format #{format.inspect} (known: #{FORMATS.join(", ")})"
        end
      end

      def known?(format) = DEFAULTS.key?(format.to_s)

      # The workload this wire serves. Every shipped format serves exactly
      # one — measured before this table was written — so the caller never
      # has to say it twice.
      def workload(format)
        WORKLOADS.fetch(format.to_s) do
          raise SimpleInference::ConfigurationError,
                "unknown api_format #{format.inspect} (known: #{FORMATS.join(", ")})"
        end
      end

      def deadline_seconds(workload)
        WORKLOAD_DEADLINE_SECONDS.fetch(workload.to_s) do
          raise SimpleInference::ConfigurationError, "unknown workload #{workload.inspect}"
        end
      end

      # WHAT A LANE'S WIRE ACCEPTS AS A MESSAGE ROLE. The protocol class is
      # the authority — it is a wire fact, so it lives beside the rest of the
      # adaptation rather than in operator-movable config, by the same line
      # that put `base_url` in the consumer's catalog and keeps every HOW
      # fact here.
      #
      # A consumer narrows its accepted input with this the way it narrows
      # media with `input_media`: the constant lists what the class's
      # normalize_role ADMITS (`developer` rides Anthropic and Gemini lowered
      # to `user` in place), so a caller who sends a role the wire refuses is
      # refused where they can still act on it.
      def accepted_roles(format)
        klass = protocol_class(format)
        klass.const_defined?(:ACCEPTED_ROLES) ? klass::ACCEPTED_ROLES : nil
      end

      # The declared input arity of a wire's route (see
      # GeminiEmbeddings::MAX_INPUT_TEXTS). `nil` means the route places no
      # bound of its own, which is every wire but one.
      def max_input_texts(format)
        klass = protocol_class(format)
        klass.const_defined?(:MAX_INPUT_TEXTS) ? klass::MAX_INPUT_TEXTS : nil
      end

      # The one protocol-selection surface in the gem. It takes a composed
      # profile rather than a bare format because the two things it reads
      # past the class — the wire options and the pre-IO input caps — are
      # exactly the facts a consumer may bend per provider and per model.
      def protocol_for(profile:, config:)
        klass = protocol_class(profile.adapter_profile)

        wire_options = klass.protocol_option_keys.to_h { |key| [key, profile.wire_options[key]] }
        # Pre-IO input caps flow from their single home — the profile's
        # local_safety_limits — into the protocol's construction keywords.
        input_caps = klass.local_safety_limit_option_keys.to_h { |key, limit_key| [key, profile.local_safety_limits[limit_key]] }

        klass.new(config: config, **wire_options.merge(input_caps).compact)
      end

      def protocol_class(format)
        PROTOCOL_CLASSES.fetch(format.to_s) do
          raise SimpleInference::ConfigurationError,
                "no conforming protocol class exists for api_format #{format.inspect}"
        end
      end
    end
  end
end
