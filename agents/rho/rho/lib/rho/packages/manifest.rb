require "json"
require "rubygems"
require_relative "../configuration"

module Rho
  class Packages
    Manifest = Data.define(:name, :id, :display_name, :description, :state_schema, :dependencies,
      :configuration_version, :schema, :default_enabled, :modes, :requires, :restart_only,
      :configuration_migrations, :directory) do
      def self.read(directory)
        document = JSON.parse(File.read(File.join(directory, "rho-extension.json"), encoding: "UTF-8")).to_h
        name = Packages.package_name(document.fetch("name"))
        id = Packages.package_name(document.fetch("id") do
          raise Rho::ConfigurationError, "#{name} needs a static id in rho-extension.json; reinstall a described package before configuration migration"
        end)
        state_schema = document.fetch("state_schema", "none").to_s
        if state_schema.empty? || state_schema.bytesize > 128
          raise Rho::ConfigurationError, "state_schema must be a nonempty string of at most 128 bytes"
        end

        dependencies = document.fetch("dependencies", {}).to_h.transform_keys(&:to_s).transform_values(&:to_s)
        dependencies.each do |gem_name, requirement|
          unless gem_name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/)
            raise Rho::ConfigurationError, "invalid dependency name"
          end
          Gem::Requirement.new(requirement)
        end
        unless File.file?(File.join(directory, "extension.rb"))
          raise Rho::ConfigurationError, "a package needs extension.rb"
        end
        version = document.fetch("configuration_version", 1)
        unless JSONSchemer.schema({ "type" => "integer", "minimum" => 1 }).valid?(version)
          raise Rho::ConfigurationError, "configuration_version must be a positive integer"
        end
        default_enabled = document.fetch("default_enabled", false)
        restart_only = document.fetch("restart_only", false)
        unless [true, false].include?(default_enabled) && [true, false].include?(restart_only)
          raise Rho::ConfigurationError, "default_enabled and restart_only must be booleans"
        end
        modes = document.fetch("modes", %w[full agent runner]).map(&:to_s)
        unless !modes.empty? && (modes - %w[full agent runner]).empty?
          raise Rho::ConfigurationError, "package modes must name full, agent or runner"
        end
        migrations = document["configuration_migrations"]&.to_s
        if migrations
          absolute = File.expand_path(migrations, directory)
          unless !migrations.empty? && !migrations.start_with?("/") && absolute.start_with?("#{File.expand_path(directory)}/")
            raise Rho::ConfigurationError, "configuration_migrations must name a relative file inside the package"
          end
        end
        new(name: name, id: id, display_name: document.fetch("display_name", name).to_s,
          description: document.fetch("description", "").to_s, state_schema: state_schema, dependencies: dependencies,
          configuration_version: version, schema: Configuration::Schema.new(document.fetch("configuration_schema", { "type" => "object", "properties" => {} })),
          default_enabled: default_enabled, modes: modes, requires: document.fetch("requires", []).map(&:to_s),
          restart_only: restart_only, configuration_migrations: migrations, directory: File.expand_path(directory))
      rescue JSON::ParserError, KeyError, NoMethodError, TypeError, Gem::Requirement::BadRequirementError
        raise Rho::ConfigurationError, "rho-extension.json must contain a name, static description and valid dependency requirements", cause: nil
      rescue Errno::ENOENT
        raise Rho::ConfigurationError, "a package needs rho-extension.json and extension.rb", cause: nil
      end

      def descriptor
        { "id" => id, "display_name" => display_name, "description" => description,
          "configuration_version" => configuration_version, "configuration_schema" => schema.schema,
          "default_enabled" => default_enabled, "modes" => modes, "requires" => requires,
          "restart_only" => restart_only, "configuration_migrations" => configuration_migrations }
      end

      def migrate(configuration, from:)
        steps = if from < configuration_version && configuration_migrations
          Configuration.load_migrations(File.join(directory, configuration_migrations))
        else
          {}
        end
        current = Configuration.migrate(configuration, from: from, to: configuration_version, steps: steps)
        schema.normalize(current)
      end

      def validate_dependencies(activate: false)
        dependencies.each do |name, requirement|
          wanted = Gem::Requirement.new(requirement)
          loaded = Gem.loaded_specs[name]
          if loaded && !wanted.satisfied_by?(loaded.version)
            raise Rho::ConfigurationError,
              "#{name} #{loaded.version} is already loaded; #{requirement} requires a compatible installation and restart"
          end
          unless loaded || Gem::Specification.find_all_by_name(name, requirement).any?
            raise Rho::ConfigurationError, "#{name} #{requirement} is unavailable; install it in rho's Ruby environment before activation"
          end
          if activate
            gem(name, requirement)
          end
        end
      end
    end
  end
end
