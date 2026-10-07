require "yaml"

module ModelCatalog
  # Strict compilation of the file base: overlays replace an entry wholesale, anything
  # malformed refuses the whole candidate. `config.d` is flat, one environment
  # mechanism: `<name>.<env>.yml` wins.
  module FileBase
    SCHEMA_VERSION = "cybros.model_catalog.v1".freeze
    TOP_LEVEL_KEYS = %w[schema_version providers models selectors].freeze
    RECOGNIZED_ENVIRONMENTS = %w[development test production].freeze

    DEFAULT_CONCURRENCY_LIMIT = Nexus::ProviderDefinition::DEFAULT_CONCURRENCY_LIMIT

    Candidate = Data.define(:providers, :models, :selectors)
    SourceFile = Data.define(:path, :content)
    SourceSet = Data.define(:shipped, :overrides)

    class << self
      # The overlay directory has ONE default and `ModelCatalog` owns it — a
      # second literal here is how a process ends up compiling a different
      # catalog than the one it booted.
      def compile(root: Rails.root.join("config/model_catalog"),
        override_dir: ModelCatalog.default_override_dir, env: Rails.env)
        compile!(root: root, override_dir: override_dir, env: env)
      rescue CompileError
        raise
      rescue StandardError => error
        # Any lower-level failure is a rejected candidate, surfaced as the
        # one typed error the catalog API promises.
        raise CompileError, "catalog compilation failed: #{error.class}: #{error.message.lines.first&.strip}"
      end

      def compile!(root:, override_dir:, env:)
        root = File.expand_path(root)
        sources = read_source_set(root, override_dir, env.to_s)
        raise CompileError, "no catalog fragments under #{root}" if sources.shipped.empty?

        base = merge_layer(
          { "providers" => {}, "models" => {}, "selectors" => {} },
          sources.shipped,
          duplicates_forbidden: true
        )
        merged = normalize_model_declarations(expand_selector_shorthand(
          merge_layer(base, sources.overrides, duplicates_forbidden: false)
        ))

        merged = normalize_provider_declarations(merged)
        validate_model_namespaces(merged)
        CatalogValidation.validate(merged)

        normalized = Nexus::CanonicalJson.normalize(merged)
        Candidate.new(
          providers: deep_freeze(normalized.fetch("providers")),
          models: deep_freeze(normalized.fetch("models")),
          selectors: deep_freeze(normalized.fetch("selectors"))
        ).freeze
      end

      private

      def normalize_provider_declarations(merged)
        merged.merge("providers" => merged.fetch("providers").to_h { |provider_id, declaration|
          definition = Nexus::ProviderDefinition.normalize(declaration, provider_id: provider_id)
          CatalogValidation.validate_provider_definition(provider_id, definition)
          [provider_id, definition]
        })
      rescue Nexus::ProviderDefinition::Invalid => error
        raise CompileError, error.message
      end

      def normalize_model_declarations(merged)
        merged.merge("models" => merged.fetch("models").to_h { |model_ref, entry|
          [model_ref, ModelDefinition.normalize(entry, model_ref: model_ref)]
        })
      end

      def expand_selector_shorthand(merged)
        merged.merge("selectors" => merged.fetch("selectors").transform_values { |candidates|
          case candidates
          when Array then candidates.map { |candidate|
            case candidate
            when String then { "model" => candidate }
            else candidate
            end
          }
          else candidates
          end
        })
      end

      def read_source_set(root, override_dir, env)
        raise CompileError, "missing catalog fragment root #{root}" unless File.directory?(root)

        SourceSet.new(
          shipped: read_files(fragment_paths(root)),
          overrides: read_files(override_paths(override_dir, env))
        ).freeze
      end

      def read_files(paths)
        paths.map do |path|
          SourceFile.new(path: path, content: File.read(path)).freeze
        end.freeze
      end

      def fragment_paths(dir)
        return [] unless File.directory?(dir)

        Dir.children(dir).select { |name| name.end_with?(".yml") }.sort
          .map { |name| File.join(dir, name) }
      end

      # Generic tier first, then the current environment's tier: later files
      # replace earlier entries wholesale, so the most specific layer wins.
      def override_paths(dir, env)
        return [] if dir.nil?

        dir = File.expand_path(dir)
        return [] unless File.directory?(dir)

        recognized = RECOGNIZED_ENVIRONMENTS | [env]
        refuse_nested_overlay(dir, recognized)
        generic, env_specific = partition_overrides(fragment_paths(dir), recognized, env)
        generic + env_specific
      end

      # A leftover environment directory is refused, not ignored: dropping
      # it silently would take the deployment's most specific overlay away.
      # Only one named for an environment — a projected volume's `..data` is not our business.
      def refuse_nested_overlay(dir, recognized)
        nested = Dir.children(dir).select do |name|
          recognized.include?(name) && File.directory?(File.join(dir, name))
        end
        return if nested.empty?

        raise CompileError,
          "#{File.basename(dir)} holds environment #{"directory".pluralize(nested.length)} " \
          "#{nested.sort.join(", ")}: overlays are FLAT — move each fragment up as " \
          "<name>.<env>.yml"
      end

      def partition_overrides(paths, recognized, env)
        generic = []
        env_specific = []
        paths.each do |path|
          suffix = environment_suffix(path)
          if suffix.nil?
            generic << path
          elsif !recognized.include?(suffix)
            raise CompileError,
              "#{File.basename(path)}: #{suffix.inspect} looks like an environment suffix " \
              "but matches no recognized environment (#{recognized.sort.join(", ")})"
          elsif suffix == env
            env_specific << path
          end
        end
        [generic, env_specific]
      end

      def environment_suffix(path)
        segments = File.basename(path, ".yml").split(".")
        return nil if segments.length < 2

        candidate = segments.last
        candidate.match?(/\A[a-z][a-z_]*\z/) ? candidate : nil
      end

      def merge_layer(accumulated, sources, duplicates_forbidden:)
        sources.each_with_object(accumulated) do |source, out|
          fragment = parse_fragment(source)
          %w[providers models selectors].each do |section|
            fragment.fetch(section, {}).each do |key, value|
              if duplicates_forbidden && out.fetch(section).key?(key)
                raise CompileError,
                  "#{File.basename(source.path)}: duplicate #{section.singularize} #{key.inspect} in the shipped layer"
              end

              out.fetch(section)[key] = value
            end
          end
        end
      end

      def parse_fragment(source)
        parsed = begin
          stream = Psych.parse_stream(source.content)
          if stream.children.length > 1
            raise CompileError,
              "#{File.basename(source.path)}: fragment must contain exactly one YAML document"
          end
          reject_duplicate_mapping_keys(stream.children.first, source.path)
          YAML.safe_load(source.content, permitted_classes: [], aliases: false)
        rescue Psych::Exception => error
          raise CompileError,
            "#{File.basename(source.path)}: not strictly parseable YAML (#{error.message.lines.first&.strip})"
        end
        case parsed
        when Hash then nil
        else raise CompileError, "#{File.basename(source.path)}: fragment must be a mapping"
        end

        unknown = parsed.keys - TOP_LEVEL_KEYS
        unless unknown.empty?
          raise CompileError, "#{File.basename(source.path)}: unknown top-level keys #{unknown.sort.join(", ")}"
        end
        unless parsed["schema_version"] == SCHEMA_VERSION
          raise CompileError,
            "#{File.basename(source.path)}: schema_version must be #{SCHEMA_VERSION.inspect} " \
            "(got #{parsed["schema_version"].inspect})"
        end
        %w[providers models selectors].each do |section|
          case parsed.fetch(section, {})
          when Hash then nil
          else raise CompileError, "#{File.basename(source.path)}: #{section} must be a mapping"
          end
        end

        parsed
      end

      def reject_duplicate_mapping_keys(node, path)
        case node
        when Psych::Nodes::Mapping
          seen = {}
          node.children.each_slice(2) do |key, value|
            case key
            when Psych::Nodes::Scalar then nil
            else
              raise CompileError,
                "#{File.basename(path)}: mapping keys must be scalar values"
            end

            identity = key.value
            if seen.key?(identity)
              raise CompileError,
                "#{File.basename(path)}: duplicate mapping key #{identity.inspect} " \
                "at line #{key.start_line + 1}"
            end

            seen[identity] = true
            reject_duplicate_mapping_keys(value, path)
          end
        when Psych::Nodes::Sequence, Psych::Nodes::Document, Psych::Nodes::Stream
          node.children.each { |child| reject_duplicate_mapping_keys(child, path) }
        else
          nil
        end
      end

      def deep_freeze(value) = ModelCatalog.deep_freeze(value)

      def validate_model_namespaces(merged)
        providers = merged.fetch("providers")
        merged.fetch("models").each_key do |model_ref|
          provider_id = Nexus::ModelRef.parse(model_ref).provider_id
          next if providers.key?(provider_id)

          raise CompileError,
            "model #{model_ref.inspect} names no declared provider (refs are provider_id/model)"
        end
      end
    end
  end
end
