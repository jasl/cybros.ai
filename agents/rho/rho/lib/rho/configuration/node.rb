module Rho
  module Configuration
    # A compiled schema node keeps schema traversal out of runtime handlers. The
    # validator owns JSON constraints; this walker owns fallback and sparse intent.
    class Node
      MISSING = Object.new.freeze
      TYPES = %w[object array string integer number boolean null].freeze
      KEYWORDS = %w[
        $schema type title description default examples writeOnly readOnly deprecated
        properties additionalProperties required items enum const
        minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
        minLength maxLength pattern format minItems maxItems uniqueItems
        minProperties maxProperties
      ].freeze
      OBJECT = JSONSchemer.schema({ "type" => "object" })

      def initialize(schema)
        unknown = schema.keys.reject { |key| KEYWORDS.include?(key) || key.start_with?("x-") }
        unless unknown.empty?
          raise ConfigurationError, "unsupported configuration schema keyword: #{unknown.first}"
        end
        dialect = schema["$schema"]
        unless dialect.nil? || dialect == "https://json-schema.org/draft/2020-12/schema"
          raise ConfigurationError, "unsupported configuration schema dialect"
        end
        @schema = schema
        @types = Array(schema.fetch("type"))
        unless (@types - TYPES).empty? && (@types - ["null"]).length <= 1
          raise ConfigurationError, "configuration schema supports one type with optional null"
        end
        @kind = (@types - ["null"]).first || "null"
        @type = JSONSchemer.schema({ "type" => @types })
        @properties = schema.fetch("properties", {}).transform_values { |child| Node.new(child) }
        additional = schema.fetch("additionalProperties", false)
        @additional = if additional == false
          nil
        elsif additional == true
          raise ConfigurationError, "configuration maps require a typed additionalProperties schema"
        else
          Node.new(additional)
        end
        @items = if @kind == "array"
          Node.new(schema.fetch("items"))
        end
        @validator = JSONSchemer.schema(validation_schema)
        @default = MISSING
        if schema.key?("default")
          unless @validator.valid?(schema.fetch("default"))
            raise ConfigurationError, "invalid configuration schema default"
          end
          answer = resolve(schema.fetch("default"), [])
          unless answer.diagnostics.empty?
            raise ConfigurationError, "invalid configuration schema default"
          end
          @default = answer.value
        end
      rescue KeyError
        raise ConfigurationError, "configuration schemas require explicit types and array items", cause: nil
      end

      def object? = @kind == "object"

      def object_value?(value) = OBJECT.valid?(value)

      def child(key)
        @properties.fetch(key) do
          @additional || raise(ConfigurationError, "unknown configuration field: #{key}")
        end
      end

      def at(path)
        path.reduce(self) do |node, key|
          unless node.object?
            raise ConfigurationError, "configuration arrays and scalar fields must be edited as a whole"
          end
          node.child(key)
        end
      end

      def resolve(raw, path)
        if raw.equal?(MISSING)
          fallback([], path)
        elsif !@type.valid?(raw)
          fallback([diagnostic(path, "type")], path)
        elsif raw.nil? && @validator.valid?(raw)
          Resolved.new(overrides: nil, value: nil, diagnostics: [])
        elsif raw.nil?
          fallback([diagnostic(path, reason(raw))], path)
        elsif object? && @schema["x-rho-atomic"] == true && !@validator.valid?(raw)
          fallback([diagnostic(path, "group_#{reason(raw)}")], path)
        elsif object?
          resolve_object(raw, path)
        elsif @kind == "array"
          resolve_array(raw, path)
        elsif @validator.valid?(raw)
          Resolved.new(overrides: raw, value: raw, diagnostics: [])
        else
          fallback([diagnostic(path, reason(raw))], path)
        end
      end

      def public_schema(inherited_secret = false)
        result = @schema.dup
        hidden = inherited_secret || secret?
        if hidden
          %w[default examples enum const].each { |key| result.delete(key) }
        end
        unless @properties.empty?
          result["properties"] = @properties.transform_values { |node| node.public_schema(hidden) }
        end
        if @additional
          result["additionalProperties"] = @additional.public_schema(hidden)
        end
        if @items
          result["items"] = @items.public_schema(hidden)
        end
        # An object/array annotation can itself contain child secret values.
        %w[default examples enum const].each do |key|
          if result.key?(key)
            result[key] = if %w[examples enum].include?(key)
              result.fetch(key).map { |value| public_annotation(value) }.reject { |value| value.equal?(MISSING) }
            else
              public_annotation(result.fetch(key))
            end
          end
        end
        result
      end

      def redact(value)
        if secret? || value.equal?(MISSING)
          MISSING
        elsif value.nil?
          nil
        elsif object?
          value.each_with_object({}) do |(key, item), result|
            node = @properties[key] || @additional
            if node
              redacted = node.redact(item)
              unless redacted.equal?(MISSING)
                result[key] = redacted
              end
            end
          end
        elsif @kind == "array"
          value.map do |item|
            redacted = @items.redact(item)
            redacted.equal?(MISSING) ? nil : redacted
          end
        else
          value
        end
      end

      def secret_fields(value, path, result)
        if secret?
          result << Secret.new(path: path, set: !value.equal?(MISSING) && !value.nil? && value != "")
        elsif object?
          object = value.equal?(MISSING) || value.nil? ? {} : value
          @properties.each do |key, node|
            node.secret_fields(object.fetch(key, MISSING), path + [key], result)
          end
          if @additional
            (object.keys - @properties.keys).each do |key|
              @additional.secret_fields(object.fetch(key), path + [key], result)
            end
          end
        elsif @kind == "array" && !value.equal?(MISSING) && !value.nil?
          value.each_with_index { |item, index| @items.secret_fields(item, path + [index.to_s], result) }
        end
        result
      end

      private

      def public_annotation(value)
        if @validator.valid?(value)
          redact(value)
        else
          MISSING
        end
      end

      def validation_schema
        result = @schema.dup
        if object? && !result.key?("additionalProperties")
          result["additionalProperties"] = false
        end
        result
      end

      def resolve_object(raw, path)
        overrides = {}
        value = {}
        diagnostics = []
        (@properties.keys | raw.keys).each do |key|
          node = @properties[key] || @additional
          if node
            answer = node.resolve(raw.fetch(key, MISSING), path + [key])
            unless answer.overrides.equal?(MISSING)
              overrides[key] = answer.overrides
            end
            unless answer.value.equal?(MISSING)
              value[key] = answer.value
            end
            diagnostics.concat(answer.diagnostics)
          else
            diagnostics << Diagnostic.new(path: path + [key], reason: "unknown_field", fallback: "unset")
          end
        end
        @schema.fetch("required", []).each do |key|
          unless value.key?(key)
            diagnostics << Diagnostic.new(path: path + [key], reason: "required", fallback: "unset")
          end
        end
        problems = @validator.validate(value).reject { |error| error.fetch("type") == "required" }
        if problems.empty?
          Resolved.new(overrides: overrides, value: value, diagnostics: diagnostics)
        else
          fallback([diagnostic(path, problems.first.fetch("type"))], path)
        end
      end

      def resolve_array(raw, path)
        answers = raw.each_with_index.map { |item, index| @items.resolve(item, path + [index.to_s]) }
        invalid = answers.flat_map(&:diagnostics).find { |diagnostic| diagnostic.reason != "unknown_field" }
        value = answers.map(&:value)
        if invalid || !@validator.valid?(value)
          fallback([diagnostic(path, invalid ? invalid.reason : reason(value))], path)
        else
          Resolved.new(overrides: answers.map(&:overrides), value: value, diagnostics: answers.flat_map(&:diagnostics))
        end
      end

      def fallback(diagnostics, path)
        value = if !@default.equal?(MISSING)
          Configuration.copy(@default)
        elsif object? && !@properties.empty?
          defaults = @properties.each_with_object({}) do |(key, node), result|
            child = node.resolve(MISSING, path + [key]).value
            unless child.equal?(MISSING)
              result[key] = child
            end
          end
          problems = @validator.validate(defaults).reject { |error| error.fetch("type") == "required" }
          defaults.empty? || !problems.empty? ? MISSING : defaults
        else
          MISSING
        end
        Resolved.new(overrides: MISSING, value: value, diagnostics: diagnostics)
      end

      def reason(raw) = @validator.validate(raw).first.fetch("type")

      def diagnostic(path, reason)
        Diagnostic.new(path: path, reason: reason, fallback: @schema.key?("default") ? "default" : "unset")
      end

      def secret? = @schema.fetch("writeOnly", false)
    end
  end
end
