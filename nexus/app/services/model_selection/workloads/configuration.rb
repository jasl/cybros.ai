module ModelSelection
  module Workloads
    # The one aspect whose vocabulary the catalog supplies: the grammar
    # knows kinds and bounds, never a provider's parameter names.
    module Configuration
      OUTPUT_FORMAT_NAME_PATTERN = /\A[a-zA-Z0-9_-]{1,64}\z/

      class << self
        include Predicates

        def normalize_configuration(configuration:, capabilities:)
          unless symbol_keyed_hash?(configuration)
            return Normalization.refused(:invalid_configuration)
          end

          values = configuration_defaults(capabilities)
          configuration.each do |name, value|
            parameter = capabilities.generation_parameters[name]
            return Normalization.refused(:unsupported_generation_parameter) unless parameter

            normalized, refusal = normalize_generation_parameter(parameter, value)
            return Normalization.refused(refusal) if refusal

            values[name] = normalized
          end

          refusal = capability_limit_refusal(values, capabilities.limits)
          return Normalization.refused(refusal) if refusal

          Normalization.accepted(Nexus::EffectiveGenerationConfig.new(values: values.freeze))
        end

        private

          def configuration_defaults(capabilities)
            capabilities.generation_parameters.each_with_object({}) do |(name, parameter), defaults|
              defaults[name] = parameter.default unless parameter.default.nil?
            end
          end

          def normalize_generation_parameter(parameter, value)
            normalized = case parameter.kind
            when :integer
              value if matches_integer?(value)
            when :number
              value if supported_number?(value)
            when :string
              value if present_string?(value)
            when :output_format
              normalize_output_format(value)
            else
              raise ArgumentError, "unhandled generation parameter kind: #{parameter.kind}"
            end
            return [nil, :invalid_generation_parameter] if normalized.nil?

            comparable = parameter.kind == :output_format ? normalized.type : normalized
            if parameter.minimum && comparable < parameter.minimum
              return [nil, :invalid_generation_parameter]
            end
            if parameter.maximum && comparable > parameter.maximum
              return [nil, :invalid_generation_parameter]
            end
            if parameter.allowed_values && !parameter.allowed_values.include?(comparable)
              return [nil, :unsupported_generation_value]
            end

            [normalized, nil]
          end

          def capability_limit_refusal(values, limits)
            result_count = values[:result_count]
            if result_count && limits.result_count && result_count > limits.result_count
              return :invalid_generation_parameter
            end

            dimensions = values[:dimensions]
            supported_dimensions = limits.embedding_dimensions
            if dimensions && supported_dimensions && !supported_dimensions.include?(dimensions)
              return :unsupported_generation_value
            end

            nil
          end

          def normalize_output_format(value)
            attributes = output_format_attributes(value)
            return unless attributes

            type = attributes[:type]
            case type
            when "text", "json_object"
              return unless attributes.keys == [:type]

              Nexus::OutputFormat.new(type: type, name: nil, schema: nil, strict: nil)
            when "json_schema"
              normalize_json_schema_output_format(attributes)
            else
              nil
            end
          end

          def output_format_attributes(value)
            case value
            when Nexus::OutputFormat
              {
                type: value.type,
                name: value.name,
                schema: value.schema,
                strict: value.strict,
              }.compact
            when Hash
              value if symbol_keyed_hash?(value)
            else
              nil
            end
          end

          def normalize_json_schema_output_format(value)
            return unless (value.keys - %i[type name schema strict]).empty?
            return unless present_string?(value[:name])
            return unless value[:name].match?(OUTPUT_FORMAT_NAME_PATTERN)
            case value[:schema]
            when Hash
              nil
            else
              return
            end
            return unless value[:strict].nil? || value[:strict] == true || value[:strict] == false

            schema = Nexus::CanonicalJson.normalize(value[:schema])
            return unless schema["type"] == "object"
            return unless Nexus::SizeBounds.json_within?(:model_output_schema_bound, schema)

            Nexus::OutputFormat.new(
              type: "json_schema", name: value[:name], schema: schema,
              strict: value[:strict].nil? ? true : value[:strict]
            )
          rescue ArgumentError
            nil
          end
      end
    end
  end
end
