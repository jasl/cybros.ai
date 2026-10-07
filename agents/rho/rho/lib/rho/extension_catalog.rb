module Rho
  module Extensions
    # Inventory is static data. Disabled implementations are never required or
    # registered merely to draw their settings form.
    class Catalog
      Descriptor = Data.define(:id, :name, :description, :version, :schema, :default_enabled,
        :modes, :requires, :restart_only, :source, :directory, :migration_file) do
        def self.from_h(row, source:, directory:)
          id = Rho::Packages.package_name(row.fetch("id"))
          description_schema = { "type" => "object", "properties" => {
            "configuration_version" => { "type" => "integer", "minimum" => 1 },
            "default_enabled" => { "type" => "boolean" },
            "restart_only" => { "type" => "boolean" },
            "modes" => { "type" => "array", "minItems" => 1,
              "items" => { "enum" => %w[full agent runner] } },
            "requires" => { "type" => "array", "items" => { "type" => "string" } },
          } }
          unless JSONSchemer.schema(description_schema).valid?(row)
            raise ConfigurationError, "#{id} has an invalid static description"
          end
          version = row.fetch("configuration_version", 1)

          new(id: id, name: row.fetch("display_name", id).to_s,
            description: row.fetch("description", "").to_s, version: version,
            schema: Configuration::Schema.new(row.fetch("configuration_schema", { "type" => "object", "properties" => {} })),
            default_enabled: row.fetch("default_enabled", false) == true,
            modes: row.fetch("modes", %w[full agent runner]).map(&:to_s),
            requires: row.fetch("requires", []).map(&:to_s),
            restart_only: row.fetch("restart_only", false) == true,
            source: source, directory: directory,
            migration_file: row["configuration_migrations"])
        end

        def migrate(configuration, from:)
          steps = {}
          if from < version && migration_file
            steps = Configuration.load_migrations(File.expand_path(migration_file.to_s, directory))
          end
          value = Configuration.migrate(configuration, from: from, to: version, steps: steps)
          schema.normalize(value)
        end
      end

      attr_reader :descriptors, :failures

      def initialize(home: nil, entries: {})
        @descriptors, @failures = {}, {}
        @entries = entries
        directory = File.dirname(__FILE__)
        JSON.parse(File.read(File.join(directory, "plugin_descriptors.json"))).each do |row|
          add(row, source: { "kind" => "builtin" }, directory: directory)
        end
        Gem.loaded_specs.each_value do |spec|
          manifest = spec.metadata["rho_extension_manifest"]
          next unless manifest

          read(File.join(spec.full_gem_path, manifest),
            source: { "kind" => "gem", "feature" => spec.metadata.fetch("rho_extensions") })
        end
        if home
          Dir.glob(File.join(home.extensions_root, "managed", "*", "*", "rho-extension.json")).sort.each do |path|
            source = { "kind" => "package", "name" => File.basename(File.dirname(File.dirname(path))),
              "version" => File.basename(File.dirname(path)) }
            read(path, source: source)
          end
        end
        entries.each { |id, entry| read_selection(id, entry, home: home) }
      end

      def fetch(id) = descriptors.fetch(id) { raise ConfigurationError, "Unknown plugin #{id}" }

      private

        def read_selection(id, entry, home:)
          source = entry["source"]
          return unless source

          case source.fetch("kind")
          when "package"
            return unless home

            directory = File.join(home.extensions_root, "managed",
              Rho::Packages.package_name(source.fetch("name")), Rho::Packages.version(source.fetch("version")))
            read(File.join(directory, "rho-extension.json"), source: source, expected: id)
          when "path"
            path = File.expand_path(source.fetch("path"))
            read(path.sub(/\.rb\z/, ".json"), source: source, expected: id)
          when "gem"
            unless @descriptors[id]&.source == source
              spec = Gem::Specification.find { |candidate| candidate.metadata["rho_extensions"] == source["feature"] }
              if spec && spec.metadata["rho_extension_manifest"]
                read(File.join(spec.full_gem_path, spec.metadata.fetch("rho_extension_manifest")), source: source, expected: id)
              else
                @failures[id] = "Plugin description is unavailable"
              end
            end
          when "builtin"
            # The immutable description above is the built-in authority.
          else
            @failures[id] = "Unknown plugin source"
          end
        rescue ConfigurationError, KeyError, TypeError, ArgumentError => error
          @failures[id] = "Plugin source failed (#{error.class.name})"
        end

        def read(path, source:, expected: nil)
          row = if source.fetch("kind") == "package"
            manifest = Rho::Packages::Manifest.read(File.dirname(path))
            manifest.descriptor
          else
            JSON.parse(File.read(path, encoding: "UTF-8")).to_h
          end
          if expected && row.fetch("id") != expected
            raise ConfigurationError, "Plugin description id does not match its saved selection"
          end
          add(row, source: source, directory: File.dirname(path))
          if manifest && @entries.dig(manifest.id, "source") == source &&
              @entries.fetch(manifest.id).fetch("enabled", manifest.default_enabled)
            begin
              # Keep the schema available even when a requested runtime cannot
              # load. Static discovery never activates a gem dependency.
              manifest.validate_dependencies
            rescue ConfigurationError => error
              @failures[manifest.id] = error.message
            end
          end
        rescue StandardError => error
          @failures[expected || source["feature"] || path] = "Plugin description failed (#{error.class.name})"
        end

        def add(row, source:, directory:)
          descriptor = Descriptor.from_h(row, source: source, directory: directory)
          id = descriptor.id
          selected = @entries.dig(id, "source")
          return if selected && selected != source

          previous = @descriptors[id]
          if previous && previous.source != source
            @failures[id] = "Multiple installed sources describe this plugin; select a source explicitly"
          else
            @descriptors[id] = descriptor
          end
        rescue ConfigurationError => error
          @failures[row.fetch("id", source.to_s)] = error.message
        end
    end
  end
end
