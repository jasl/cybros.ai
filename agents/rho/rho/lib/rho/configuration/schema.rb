require_relative "node"

module Rho
  module Configuration
    class Schema
      attr_reader :schema

      def initialize(schema)
        @schema = Configuration.copy(schema.to_h)
        dialect = @schema["$schema"]
        unless dialect.nil? || dialect == "https://json-schema.org/draft/2020-12/schema"
          raise ConfigurationError, "unsupported configuration schema dialect"
        end
        unless JSONSchemer.validate_schema(@schema).none?
          raise ConfigurationError, "invalid configuration schema"
        end
        @root = Node.new(@schema)
        unless Array(@schema.fetch("type")) == ["object"]
          raise ConfigurationError, "configuration schema must describe an object"
        end
      end

      def normalize(raw)
        answer = @root.resolve(Configuration.copy(raw), [])
        Resolved.new(
          overrides: answer.overrides.equal?(Node::MISSING) ? {} : answer.overrides,
          value: answer.value.equal?(Node::MISSING) ? {} : answer.value,
          diagnostics: answer.diagnostics
        )
      end

      def edit(raw, operations:)
        candidate = Configuration.copy(raw)
        unless @root.object_value?(candidate)
          candidate = {}
        end
        edited_paths = []
        operations.each do |input|
          operation = input.to_h.transform_keys(&:to_s)
          path = operation.fetch("path").map(&:to_s)
          if path.empty?
            raise ConfigurationError, "configuration edits require a field path"
          end
          node = @root.at(path)
          case operation.fetch("op")
          when "set"
            value = Configuration.copy(operation.fetch("value"))
            checked = node.resolve(value, path)
            problems = checked.diagnostics.reject { |diagnostic| diagnostic.reason == "required" }
            unless problems.empty?
              raise ConfigurationError, "invalid configuration edit at #{JSON.generate(path)}: #{problems.first.reason}"
            end
            write(candidate, path, value)
          when "unset"
            remove(candidate, path)
          else
            raise ConfigurationError, "configuration edit must be set or unset"
          end
          edited_paths << path
        end
        result = normalize(candidate)
        problem = result.diagnostics.find do |diagnostic|
          diagnostic.reason != "required" && edited_paths.any? do |path|
            diagnostic.path.take(path.length) == path || path.take(diagnostic.path.length) == diagnostic.path
          end
        end
        if problem
          raise ConfigurationError, "invalid configuration edit at #{JSON.generate(problem.path)}: #{problem.reason}"
        end
        result
      end

      def view(resolved)
        secrets = []
        @root.secret_fields(resolved.value, [], secrets)
        View.new(
          schema: @root.public_schema,
          overrides: public_value(resolved.overrides),
          value: public_value(resolved.value),
          diagnostics: resolved.diagnostics,
          secrets: secrets
        )
      end

      private

      def public_value(value)
        redacted = @root.redact(value)
        redacted.equal?(Node::MISSING) ? {} : redacted
      end

      def write(document, path, value)
        parent = document
        node = @root
        path[0...-1].each do |key|
          node = node.child(key)
          unless node.object_value?(parent[key])
            parent[key] = {}
          end
          parent = parent.fetch(key)
        end
        parent[path.last] = value
      end

      def remove(document, path)
        parent = document
        node = @root
        path[0...-1].each do |key|
          node = node.child(key)
          if node.object_value?(parent[key])
            parent = parent.fetch(key)
          else
            return
          end
        end
        parent.delete(path.last)
      end
    end
  end
end
