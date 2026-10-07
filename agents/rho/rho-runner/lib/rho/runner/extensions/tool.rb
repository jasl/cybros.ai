module Rho
  class Runner
    module Extensions
      # WHAT A TOOL CLASS MUST CARRY, checked at LOAD rather than at call.
      #
      # These four constants and one method are not a new contract: they
      # are exactly what all seven built-ins already declare, written down
      # so a third party can satisfy it deliberately instead of by
      # imitation. The built-ins register through this same door, so
      # nothing has a privileged path into the loop — which is what
      # `Toolset`'s own comment said the frozen table was standing in for.
      #
      # VALIDATED AT LOAD, because the alternative is a task parked to its
      # deadline. A tool whose NAME the provider will not accept, or whose
      # SCHEMA is not an object, fails at the moment somebody can still
      # read the error — not ten minutes later as a timed-out round with
      # nothing to read.
      module Tool
        # THE PROVIDER'S FLOOR, and the reason canonical names cannot ride
        # the wire: OpenAI and Anthropic both accept only these bytes in a
        # function name. `rho.web_tools.fetch` is the canonical spelling a human
        # writes in documentation; `web_fetch` is what a model is offered,
        # mirroring how the kernel's own registry keeps the two apart.
        NAME_FORMAT = /\A[a-zA-Z0-9_-]{1,64}\z/
        # `DESCRIPTION` must be DECLARED and may be nil: a tool described to
        # nobody is served but announced without its
        # description or its schema, so no agent can author a declaration
        # from it through discovery — the shape a runner uses for a
        # capability a PERSON requests (`files_bytes`, `process_log`) that
        # no model should be handed. Its `SCHEMA` still stands: the run
        # validates every call against it before the handler sees one.
        REQUIRED_CONSTANTS = %i[NAME DESCRIPTION SCHEMA EFFECT_PROFILE].freeze
        # OPTIONAL: a per-tool park, announced to the kernel as `timeout_ms`
        # so a row addressed to this tool expires on the tool's
        # own clock rather than the kernel's default. Bounded by the
        # kernel's own ceiling on a park.
        MAX_TIMEOUT_MS = 7 * 24 * 60 * 60 * 1000
        # The kernel's closed vocabulary, mirrored: it is trusted host
        # metadata for an inventory and a future approval gate, and it
        # never rides the provider wire.
        EFFECT_KEYS = %w[kind destructive effect_scope idempotency reconciliation].freeze
        # THE VALUES, mirrored too (`Nexus::ToolRegistry`, spelled once more
        # as NAME_FORMAT already is): the kernel's door judges every value
        # and refuses the ENTIRE announcement on one stranger, after which
        # every tool on that address answers `tool_not_served` — so a
        # profile the door would refuse is refused here, at LOAD, for every
        # extension (one `"kind": "readonly"` in an operator's file must cost that row, never the whole runner).
        EFFECT_KINDS = %w[pure read_only write].freeze
        EFFECT_SCOPES = %w[closed open].freeze
        IDEMPOTENCY_KINDS = %w[intrinsic keyed none].freeze
        RECONCILIATION_KINDS = %w[none lookup].freeze
        DESTRUCTIVE = [true, false].freeze
        EFFECT_VALUES = {
          "kind" => EFFECT_KINDS, "destructive" => DESTRUCTIVE, "effect_scope" => EFFECT_SCOPES,
          "idempotency" => IDEMPOTENCY_KINDS, "reconciliation" => RECONCILIATION_KINDS,
        }.freeze

        module_function

        def validate(klass, extension:)
          begin
            missing = REQUIRED_CONSTANTS.reject { |name| klass.const_defined?(name, false) }
          rescue NoMethodError
            raise RegistrationError, "#{extension} registered #{klass.inspect}, which is not a class"
          end

          unless missing.empty?
            raise RegistrationError,
              "#{extension}'s #{klass} is missing #{missing.join(", ")}"
          end

          validate_name(klass, extension)
          validator = compile_schema(klass, extension)
          validate_effect_profile(klass, extension)
          validate_timeout(klass, extension)

          unless klass.method_defined?(:call)
            raise RegistrationError, "#{extension}'s #{klass} does not define #call(args)"
          end

          validator
        end

        def validate_name(klass, extension)
          name = klass::NAME.to_s
          return if name.match?(NAME_FORMAT)

          raise RegistrationError,
            "#{extension}'s #{klass} has NAME #{name.inspect}; a provider accepts only " \
            "letters, digits, underscore and hyphen (a dotted canonical name is not a wire name)"
        end

        # An object, AND one the validator compiles: every call is checked
        # against it (`InputSchema`), so a schema json_schemer refuses
        # would refuse every call with the validator's own exception —
        # ten minutes later, as a failed task with nothing to read.
        def compile_schema(klass, extension)
          schema = Hash.try_convert(klass::SCHEMA)
          unless schema && schema["type"] == "object"
            raise RegistrationError,
              "#{extension}'s #{klass} has a SCHEMA that is not a JSON Schema object"
          end

          InputSchema.compile(schema)
        rescue ArgumentError => error
          raise RegistrationError, "#{extension}'s #{klass} has #{error.message}"
        end

        def validate_effect_profile(klass, extension)
          fault = effect_profile_fault(klass::EFFECT_PROFILE)
          return if fault.nil?

          raise RegistrationError, "#{extension}'s #{klass} must declare EFFECT_PROFILE #{fault}"
        end

        # nil for a profile the kernel's door would store, else one clause
        # naming the fault — the keys first, then the first value outside
        # the vocabulary. Public because an extension that curates profiles
        # written by an OPERATOR (rho-mcp's `effect_profiles`) reads the
        # same vocabulary before it builds a class, so the fault is that
        # row's sentence and never a half-staged handle.
        def effect_profile_fault(value)
          profile = Hash.try_convert(value)
          return "with exactly #{EFFECT_KEYS.join(", ")}" unless profile && profile.keys.sort == EFFECT_KEYS.sort

          EFFECT_VALUES.each do |key, allowed|
            next if allowed.include?(profile[key])

            return "with #{key} one of #{allowed.map(&:inspect).join(", ")}, not #{profile[key].inspect}"
          end
          nil
        end

        # A TIMEOUT_MS, when declared, is a positive Integer within the
        # bound — refused at load, where somebody can still read it, rather
        # than as a row the kernel refuses to park or parks for a week.
        def validate_timeout(klass, extension)
          value = timeout_ms(klass)
          return if value.nil?

          integer = Integer.try_convert(value)
          return if integer && integer.eql?(value) && integer.positive? && integer <= MAX_TIMEOUT_MS

          raise RegistrationError,
            "#{extension}'s #{klass} has TIMEOUT_MS #{value.inspect}; a per-tool timeout is a " \
            "positive Integer of milliseconds no greater than #{MAX_TIMEOUT_MS} (seven days)"
        end

        def timeout_ms(klass)
          klass.const_defined?(:TIMEOUT_MS, false) ? klass::TIMEOUT_MS : nil
        end

        # A nil `DESCRIPTION` is the one fact: announced schema-less, offered
        # to no model.
        def undescribed?(klass) = klass::DESCRIPTION.nil?

        # The kernel's announcement shape, also used by a tool source
        # budgeting its bytes before registration. Rendering does not
        # admit a class or compile its schema.
        def announcement(klass, name:)
          facts = { "name" => name, "effect_profile" => klass::EFFECT_PROFILE, "timeout_ms" => timeout_ms(klass) }
          facts = facts.merge("description" => klass::DESCRIPTION, "input_schema" => klass::SCHEMA) unless undescribed?(klass)
          facts.compact
        end

        # OPTIONAL: `INTERNAL_CLAMP = true` says the handler bounds its own
        # run (bash's wall-clock timeout) and must never be extended; a
        # handler without one — a provider's, the delegated compaction —
        # is extended at half its park while it runs (executor.md "Extend").
        def internal_clamp?(klass)
          klass.const_defined?(:INTERNAL_CLAMP, false) && klass::INTERNAL_CLAMP == true
        end

        # OPTIONAL, and read rather than required: the prompt fragments a
        # host assembles into an "Available tools" section. Every built-in
        # already declares them and nothing has ever read them — the
        # reader is the task author, which is one round away.
        def prompt_snippet(klass)
          klass.const_defined?(:PROMPT_SNIPPET, false) ? klass::PROMPT_SNIPPET : nil
        end

        def prompt_guidelines(klass)
          klass.const_defined?(:PROMPT_GUIDELINES, false) ? Array(klass::PROMPT_GUIDELINES) : []
        end
      end
    end
  end
end
