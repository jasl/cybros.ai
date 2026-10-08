module ModelCatalog
  # Where catalog entries become the execution profile (catalog owns the
  # models, 2026-08-21): the gem says what a wire is, and three layers —
  # format, provider, model — each override the one before.
  module ProfileBuilder
    # `credentials` is the operator's word for which lane authenticates this
    # provider; the gem still spells the OAuth one `oauth_tokens` internally.
    CREDENTIALS = Nexus::ProviderDefinition::CREDENTIALS
    DEFAULT_CREDENTIALS = Nexus::ProviderDefinition::DEFAULT_CREDENTIALS

    class << self
      def call(model_ref:, provider:, model:)
        provider_id, model_tail = Nexus::ModelRef.parse(model_ref).deconstruct
        format = model["api_format"] || provider["api_format"]
        workload = SimpleInference::ApiFormat.workload(format)
        defaults = SimpleInference::ApiFormat.defaults(format)

        SimpleInference::ExecutionProfile.new(
          profile_id: profile_id_for(model_ref, format),
          provider_id: provider_id,
          adapter_profile: format,
          workload: workload,
          model_pin: model["model_id"] || model_tail,
          credential_lane: credential_lane(provider),
          authentication: provider["authentication"],
          request_headers: request_headers(provider, model),
          total_execution_deadline_seconds:
            model["deadline_seconds"] || SimpleInference::ApiFormat.deadline_seconds(workload),
          **defaults.merge(stated(format, defaults, provider, model, workload))
        )
      end

      # A derived identity for one lane, so a selection and a log line can
      # name it; nothing keys behaviour off its shape.
      def profile_id_for(model_ref, format) = "#{model_ref}@#{format}"

      def credential_lane(provider)
        declared = provider["credentials"] || DEFAULT_CREDENTIALS
        CREDENTIALS.fetch(declared) do
          raise ModelCatalog::CompileError,
                "credentials #{declared.inspect} is not one of #{CREDENTIALS.keys.join(", ")}"
        end
      end

      # MERGED, not replaced: a model that bends one wire option (xAI's
      # image endpoint needs inline delivery requested explicitly) still
      # speaks the rest of its format.
      def wire_options(defaults, provider, model)
        (defaults[:wire_options] || {})
          .merge(symbolize(provider["wire_options"]))
          .merge(symbolize(model["wire_options"]))
      end

      private

        def request_headers(provider, model)
          SimpleInference::Config.normalize_request_headers(provider.fetch("request_headers", {}))
            .merge(SimpleInference::Config.normalize_request_headers(model.fetch("request_headers", {})))
        end

        # Mapped one fact at a time: the catalog's `capabilities` and the
        # profile's are different shapes under one name.
        def stated(format, defaults, provider, model, workload)
          caps = model["capabilities"] || {}
          out = {}
          out[:wire_options] = wire_options(defaults, provider, model)
          contract = model["native_cost_contract"] || provider["native_cost_contract"]
          out[:native_cost_contract] = contract.nil? ? defaults[:native_cost_contract] : mapping(contract, "native_cost_contract")
          out[:local_safety_limits] = limits(caps, model, workload)
          modalities = caps["input_modalities"] || model["input_modalities"]
          out[:input_modalities] = modalities if modalities
          out[:output_modalities] = caps["output_modalities"] if caps["output_modalities"]
          out[:input_media] = media(defaults, caps, model, modalities)
          out[:capabilities] = capabilities(format, defaults, caps)
          parameters = generation_parameters(format, caps)
          out[:generation_parameters] = parameters if
            caps.key?("generation_parameters") || parameters.key?("output_format")
          out[:reasoning_options] = reasoning_options(defaults, caps["reasoning"])
          tiers = caps["service_tiers"] || provider["service_tiers"]
          out[:service_tiers] = tiers if tiers
          # Omission inherits the wire's counter; explicit null selects the
          # existing byte estimate. Preserve that distinction after compacting.
          out = out.compact
          if model.key?("token_counter")
            counter = model["token_counter"]
            out[:token_counter] = counter.nil? ? nil : mapping(counter, "token_counter")
          end
          out
        end

        # Which of the wire's reasoning words this model has; only the
        # list-valued keys cross, since the profile's shape is vocabularies.
        REASONING_LIST_KEYS = %w[efforts modes contexts summaries].freeze
        # Budget modes are wire vocabulary. Enablement and its default belong
        # to the catalog and the selected request, not this vocabulary map.
        REASONING_WIRE_KEYS = %w[budgets].freeze

        # Silence carries no vocabulary; a switch-only declaration also needs
        # no effort words. The catalog remains the reasoning-capability owner.
        def reasoning_options(defaults, declared)
          narrowed = Hash(declared).slice(*REASONING_LIST_KEYS)
          return {} if narrowed.empty?

          Hash(defaults[:reasoning_options]).slice(*REASONING_WIRE_KEYS).merge(narrowed)
        end

        # THE WIRES' DEFAULTS, not per-model claims on evidence: each
        # feature is a fact of the lane's protocol — whether it accepts
        # `tools` by name, whether it parses a stream, whether its provider
        # caches a stable prefix (every text wire; the breakpoints the
        # kernel places are a narrower, Anthropic-only fact Build reads
        # separately) — read from the lowering here and nowhere else. A row
        # silent on a key has the capability wherever its wire carries it;
        # `false` is the explicit opt-out for a model known not to; a
        # written `true` says nothing more than silence, so a claiming row
        # and a silent one build one profile, and a `true` on a wire
        # without the feature claims nothing.
        WIRE_CAPABILITIES = {
          "streaming" => :carries_streaming?,
          "tool_calls" => :carries_function_tools?,
          "prompt_caching" => :carries_prompt_caching?,
        }.freeze

        def capabilities(format, defaults, caps)
          derived = WIRE_CAPABILITIES.select do |key, carries|
            caps[key] != false && ModelRequests::WireLowering.public_send(carries, format)
          end.keys
          (Array(defaults[:capabilities]) - WIRE_CAPABILITIES.keys + derived).uniq
        end

        # STRUCTURED OUTPUT IS THE WIRE'S DEFAULT TOO: a text lane whose
        # protocol carries `response_format` offers `output_format` with the
        # wire's own kinds and NO default, so a plain turn still sends
        # nothing. A row's own descriptor stands as written (a narrower
        # vocabulary is the row's fact); `output_format: false` is the one
        # opt-out, for a model known not to.
        def generation_parameters(format, caps)
          declared = Hash(caps["generation_parameters"])
          return declared.except("output_format") if declared["output_format"] == false
          return declared if declared.key?("output_format") ||
            !ModelRequests::WireLowering.carries_output_format?(format)

          declared.merge("output_format" => wire_output_format(format))
        end

        def wire_output_format(format)
          {
            "kind" => "output_format",
            "default" => nil,
            "minimum" => nil,
            "maximum" => nil,
            "allowed_values" => ModelRequests::WireLowering.allowed_output_formats(format),
          }
        end

        # The wire's media bounds, applied only to the modalities the model
        # accepts; a text-only model carries none.
        def media(defaults, caps, model, modalities)
          declared = caps["input_media"] || model["input_media"]
          return declared if declared

          Hash(defaults[:input_media]).slice(*Array(modalities))
        end

        # This is the merge boundary for both provider and model wire options.
        def symbolize(value)
          mapping(value.nil? ? {} : value, "wire_options").to_h { |key, inner| [key.to_sym, inner] }
        end

        def mapping(value, field)
          Hash.try_convert(value) || raise(CompileError, "#{field} must be a mapping")
        end

        # An unstated window gets the conservative default, here only, and
        # only where a token window means anything.
        def limits(caps, model, workload)
          # The soft advisory threshold belongs to Nexus's estimate response,
          # not the Provider execution profile, so strip it at this boundary.
          declared = Hash(caps["limits"] || model["limits"])
            .except(*CatalogValidation::NEXUS_ONLY_LIMIT_KEYS)
          return declared if declared.any?
          return {} unless workload == "text_generation"

          { "input_tokens" => SimpleInference::ApiFormat::DEFAULT_INPUT_TOKENS }
        end
    end
  end
end
