module ModelCatalog
  # File entries and stored overrides share one authoring grammar. Fill omitted
  # descriptor fields here so validation and execution read complete values.
  module ModelDefinition
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
      def normalize(entry, model_ref:)
        entry = mapping(entry, model_ref, "entry")
        flat = entry.slice(*CatalogValidation::CAPABILITY_KEYS)
        return entry if flat.empty? && !entry.key?("capabilities")

        capabilities = flat.merge(mapping(entry.fetch("capabilities", {}), model_ref, "capabilities"))
        if capabilities.key?("generation_parameters")
          capabilities = capabilities.merge("generation_parameters" =>
            generation_parameters(capabilities.fetch("generation_parameters"), model_ref))
        end
        entry.except(*CatalogValidation::CAPABILITY_KEYS).merge("capabilities" => capabilities)
      end

      private

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
