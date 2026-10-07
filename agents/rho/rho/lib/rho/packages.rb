require "digest"
require "fileutils"
require "tmpdir"
require_relative "packages/manifest"
require_relative "packages/selection"
require_relative "packages/legacy"
require_relative "packages/check"

module Rho
  # Installed source and assembly choices are local application configuration.
  # The daemon's existing boot lock and settings serialization own its writers.
  class Packages
    def self.package_name(value)
      name = value.to_s
      unless name.bytesize <= 64 && name.match?(/\A[a-z][a-z0-9_.-]*\z/)
        raise Rho::ConfigurationError, "package name must start with a lowercase letter and contain at most 64 letters, digits, dots, hyphens or underscores"
      end
      name
    end

    def self.version(value)
      version = value.to_s
      unless version.match?(/\A[0-9a-f]{64}\z/)
        raise Rho::ConfigurationError, "package version must be the full installed SHA-256 digest"
      end
      version
    end

    def initialize(home:)
      @home = home
      @root = File.join(home.extensions_root, "managed")
    end

    def sources(plugins: read_settings.fetch("plugins", {}))
      plugins.sort.filter_map do |id, row|
        next unless row.fetch("source", {})["kind"] == "package"

        configured_source(id, row)
      end
    end

    def list
      entries = read_entries(read_settings.fetch("plugins", {}))
      rows = Dir.glob(File.join(@root, "*", "*", "rho-extension.json")).sort.map do |path|
        directory = File.dirname(path)
        manifest = Manifest.read(directory)
        version = File.basename(directory)
        entry = entries[manifest.id]
        selected = entry && entry.selection.name == manifest.name && entry.selection.version == version
        enabled = !!(selected && entry.enabled?(default: manifest.default_enabled))
        { name: manifest.name, id: manifest.id, version: version, description: manifest.description,
          state_schema: manifest.state_schema, dependencies: manifest.dependencies,
          configuration_version: manifest.configuration_version,
          selected: !!selected, enabled: enabled,
          previous: entry&.previous&.name == manifest.name && entry.previous.version == version }
      end
      { packages: rows }
    end

    # Installation copies a candidate; it neither evaluates Ruby nor changes
    # the selection. Reinstalling identical bytes names the same local version.
    def install(path:)
      raise Rho::ConfigurationError, "package source directory is required" if path.to_s.empty?

      source = File.expand_path(path.to_s)
      unless File.directory?(source)
        raise Rho::ConfigurationError, "package source must be a directory"
      end
      manifest = Manifest.read(source)
      FileUtils.mkdir_p(@root, mode: 0o700)
      staging = Dir.mktmpdir(".install-", @root)
      files = Dir.glob("**/*", File::FNM_DOTMATCH, base: source).sort.reject { |name| name.split("/").include?(".git") }
      files.each do |relative|
        original = File.join(source, relative)
        destination = File.join(staging, relative)
        if File.symlink?(original)
          raise Rho::ConfigurationError, "managed package files must not be symlinks: #{relative}"
        elsif File.directory?(original)
          FileUtils.mkdir_p(destination)
        elsif File.file?(original)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.copy_file(original, destination)
        else
          raise Rho::ConfigurationError, "managed package files must be regular files: #{relative}"
        end
      end
      version = digest(staging)
      destination = directory(manifest.name, version)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      File.rename(staging, destination) unless File.directory?(destination)
      { name: manifest.name, id: manifest.id, version: version, installed: true }
    ensure
      FileUtils.rm_rf(staging) if staging && File.directory?(staging)
    end

    def check(name:, version: nil)
      name = Packages.package_name(name)
      current = entry_for(name, read_entries(read_settings.fetch("plugins", {})))
      version = resolve_version(name, version, current: current)
      path = directory(name, version)
      Manifest.read(path).validate_dependencies
      Check.run(path).merge(name: name, version: version)
    end

    def activate(name:, version: nil, configuration: nil)
      name = Packages.package_name(name)
      plugins = read_settings.fetch("plugins", {})
      entries = read_entries(plugins)
      installed = entry_for(name, entries)
      version = resolve_version(name, version, current: installed)
      manifest = Manifest.read(directory(name, version))
      current = entries[manifest.id]
      if (plugins.key?(manifest.id) && current.nil?) || (installed && installed != current)
        raise Rho::ConfigurationError, "plugin #{manifest.id} already has another configured source or runtime identity"
      end
      selection = prepare_selection(manifest, version, current: current, configuration: configuration)
      validate_business_state(name, current&.selection, selection)
      manifest.validate_dependencies(activate: true)
      previous = if current&.selection == selection
        current.previous
      else
        current&.selection
      end
      entry = Entry.new(enabled: true, selection: selection, previous: previous)
      publish(entries.merge(manifest.id => entry), id: manifest.id, name: name, action: "activate") do |sources, persist, candidate_document|
        yield sources, persist, candidate_document
      end
    end

    def disable(name:)
      name = Packages.package_name(name)
      entries = read_entries(read_settings.fetch("plugins", {}))
      id, current = entries.find { |_id, entry| entry.selection.name == name }
      if current.nil?
        raise Rho::ConfigurationError, "no selected package #{name}"
      end
      publish(entries.merge(id => current.with(enabled: false)), id: id, name: name, action: "disable") do |sources, persist, candidate_document|
        yield sources, persist, candidate_document
      end
    end

    # Code rollback cannot undo a migration of a package's business state.
    # The complete previous configuration belongs to that previous code version.
    def rollback(name:)
      name = Packages.package_name(name)
      entries = read_entries(read_settings.fetch("plugins", {}))
      id, current = entries.find { |_id, entry| entry.selection.name == name }
      if current.nil? || current.previous.nil?
        raise Rho::ConfigurationError, "#{name} has no previous version"
      end
      previous = current.previous
      validate_business_state(name, current.selection, previous)
      manifest = Manifest.read(directory(previous.name, previous.version))
      unless manifest.id == id && manifest.configuration_version == previous.configuration_version
        raise Rho::ConfigurationError, "#{name} rollback requires configuration matching the selected version"
      end
      manifest.validate_dependencies(activate: true)
      entry = Entry.new(enabled: true, selection: previous, previous: current.selection)
      publish(entries.merge(id => entry), id: id, name: name, action: "rollback") do |sources, persist, candidate_document|
        yield sources, persist, candidate_document
      end
    end

    private

      def read_settings
        Config.read(@home.settings_path)
      end

      def read_entries(plugins)
        plugins.to_h.each_with_object({}) do |(id, value), entries|
          row = value.to_h
          if row.fetch("source", {}).to_h["kind"] == "package"
            entries[id] = Entry.from_h(row)
          end
        end
      rescue KeyError, NoMethodError, TypeError
        raise Rho::StateError, "managed package settings are malformed", cause: nil
      end

      def entry_for(name, entries)
        entries.values.find { |entry| entry.selection.name == name }
      end

      def prepare_selection(manifest, version, current:, configuration:)
        prepared = if configuration.nil?
          selected = current&.selection
          manifest.migrate(selected&.configuration || {}, from: selected&.configuration_version || manifest.configuration_version)
        else
          operations = Configuration.copy(configuration.to_h).map do |key, value|
            { "op" => "set", "path" => [key], "value" => value }
          end
          manifest.schema.edit({}, operations: operations)
        end
        Selection.new(name: manifest.name, version: version, configuration_version: manifest.configuration_version,
          configuration: prepared.overrides, state_schema: manifest.state_schema)
      end

      def validate_business_state(name, current, candidate)
        if current && current.state_schema != candidate.state_schema
          raise Rho::ConfigurationError,
            "#{name} activation requires business-state recovery: state_schema differs (#{current.state_schema} to #{candidate.state_schema})"
        end
      end

      def selected_sources(entries)
        entries.sort.filter_map do |id, entry|
          selected_source(id, entry)
        end
      end

      def selected_source(id, entry)
        configured_source(id, entry.to_h)
      end

      # Runtime selection does not need rollback history. A broken optional
      # selection is diagnosed by static inventory without blocking core boot.
      def configured_source(id, row)
        return nil if row["enabled"] == false

        source = row.fetch("source")
        name, version = Packages.package_name(source.fetch("name")), Packages.version(source.fetch("version"))
        manifest = Manifest.read(directory(name, version))
        if row.fetch("enabled", manifest.default_enabled) && manifest.id == id &&
            manifest.configuration_version == row.fetch("configuration_version", manifest.configuration_version)
          manifest.validate_dependencies(activate: true)
          Source.new(path: File.join(directory(name, version), "extension.rb"), id: id,
            revision: version[0, 12], configuration_version: manifest.configuration_version,
            configuration: manifest.schema.normalize(row.fetch("configuration", {})).value)
        end
      rescue Rho::ConfigurationError, KeyError, TypeError
        # Static inventory owns the diagnostic. A pending or unavailable optional
        # package must not prevent loading the rest of the requested selection.
        nil
      end

      def publish(entries, id:, name:, action:)
        warning = nil
        persistence = "not_saved"
        entry = entries.fetch(id)
        document = read_settings
        candidate_document = document.merge("plugins" => document.fetch("plugins", {}).merge(id => entry.to_h))
        persist = lambda do
          latest = read_settings
          plugins = latest.fetch("plugins", {}).merge(id => entry.to_h)
          @home.write_settings(latest.merge("plugins" => plugins))
          persistence = "saved"
          nil
        rescue StateFile::PublishedError => error
          persistence = "published_durability_uncertain"
          warning = error.message
          nil
        end
        # Other saved selections can still be waiting for restart or repair.
        # Only this operation's package may activate dependency requirements.
        outcome = yield selected_sources(entries.slice(id)), persist, candidate_document
        facts = { action: action, name: name, id: id, enabled: entry.enabled,
          selected: entry.selection.version,
          previous: entry.previous&.version, persistence: persistence }
        result = outcome.to_h.merge(facts)
        if warning
          result[:warning] = [result[:warning], warning].compact.join(" ")
        end
        result
      end

      def resolve_version(name, version, current: nil)
        return Packages.version(version) unless version.nil?
        return current.selection.version if current

        versions = Dir.glob(File.join(@root, name, "*", "rho-extension.json")).map { |path| File.basename(File.dirname(path)) }
        if versions.length != 1
          raise Rho::ConfigurationError, "name an installed version of #{name}; rho extensions list shows full versions"
        end
        versions.first
      end

      def directory(name, version)
        File.join(@root, name, version)
      end

      def digest(path)
        hash = Digest::SHA256.new
        Dir.glob("**/*", File::FNM_DOTMATCH, base: path).sort.each do |relative|
          file = File.join(path, relative)
          next unless File.file?(file)

          hash << relative << "\0" << File.size(file).to_s << "\0"
          File.open(file, "rb") { |input| hash << input.read(64 * 1024) until input.eof? }
        end
        hash.hexdigest
      end
  end
end
