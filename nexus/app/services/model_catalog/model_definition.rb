module ModelCatalog
  # File entries and stored overrides share one authoring grammar. Resolve a
  # reusable definition before filling defaults, preserving authored omissions.
  module ModelDefinition
    NAME_PATTERN = /\A[a-z0-9][a-z0-9_.-]*\z/
    MAX_NAME_BYTES = 256
    PARAMETER_DEFAULTS = {
      "default" => nil, "minimum" => nil, "maximum" => nil, "allowed_values" => nil,
    }.freeze
    PARAMETER_PRESETS = {
      "max_output_tokens" => { "kind" => "integer", "minimum" => 1 }.freeze,
      "verbosity" => {
        "kind" => "string", "default" => "low", "allowed_values" => %w[low medium high].freeze,
      }.freeze,
    }.freeze

    class << self
      def normalize(entry, model_ref:, definitions: {})
        entry = authoring_shape(entry, model_ref: model_ref)
        if entry.key?("inherit")
          name = named_agent_name(entry.fetch("inherit"), model_ref)
          base = definitions.fetch(name) do
            raise CompileError, "model #{model_ref}: unknown inherited model definition #{name.inspect}"
          end
          entry = merge_definition(base, entry.except("inherit"))
        end
        fill_parameter_defaults(entry, model_ref)
      end

      # Keep only authored values here: filling descriptor defaults on the base
      # or an override before they merge would turn an omission into a reset.
      def normalize_definitions(definitions)
        definitions.to_h do |name, declaration|
          name = named_agent_name(name, "definition")
          entry = authoring_shape(declaration, model_ref: name)
          CatalogValidation.validate_definition(name, fill_parameter_defaults(entry, name))
          [name, entry]
        end
      end

      # Editors retain inheritance and omitted fields while sharing the same
      # flat-or-nested capability grammar as the execution compiler.
      def authoring_shape(entry, model_ref:)
        entry = mapping(entry, model_ref, "entry")
        flat = entry.slice(*CatalogValidation::CAPABILITY_KEYS)
        return entry if flat.empty? && !entry.key?("capabilities")

        capabilities = flat.merge(mapping(entry.fetch("capabilities", {}), model_ref, "capabilities"))
        entry.except(*CatalogValidation::CAPABILITY_KEYS).merge("capabilities" => capabilities)
      end

      private

        def named_agent_name(value, model_ref)
          name = String.try_convert(value)
          unless name && name.bytesize <= MAX_NAME_BYTES && name.match?(NAME_PATTERN)
            raise CompileError, "model #{model_ref}: model definition name must contain lowercase letters, digits, dots, underscores or hyphens"
          end
          name
        end

        def merge_definition(base, entry)
          merged = base.deep_merge(entry)
          capabilities = entry.fetch("capabilities", {})
          if capabilities.key?("limits")
            # A deployment window is one contract: merging its members can mix
            # a shared window with independent input limits or stale soft bounds.
            merged["capabilities"]["limits"] = capabilities.fetch("limits")
          end
          merged
        end

        def fill_parameter_defaults(entry, model_ref)
          capabilities = entry.fetch("capabilities", {})
          if capabilities.key?("generation_parameters")
            capabilities = capabilities.merge("generation_parameters" =>
              generation_parameters(capabilities.fetch("generation_parameters"), model_ref))
            entry.merge("capabilities" => capabilities)
          else
            entry
          end
        end

        def generation_parameters(parameters, model_ref)
          mapping(parameters, model_ref, "generation_parameters").to_h do |name, descriptor|
            value = if name == "output_format" && descriptor == false
              false
            else
              PARAMETER_DEFAULTS.merge(PARAMETER_PRESETS.fetch(name, {}))
                .merge(mapping(descriptor, model_ref, "generation parameter #{name}"))
            end
            [name, value]
          end
        end

        def mapping(value, model_ref, field)
          Hash.try_convert(value) || raise(CompileError, "model #{model_ref}: #{field} must be a mapping")
        end
    end
  end
end
