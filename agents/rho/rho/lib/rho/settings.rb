require "async/semaphore"
require_relative "configuration/settings_migration"

module Rho
  # The existing daemon writer serializes core and plugin edits. Every edit is
  # applied to the latest document, so unrelated form saves preserve each other.
  class Settings
    class ApplyError < Error
      attr_reader :restart_required, :applied, :published
      def initialize(message, restart_required: false, applied: false, published: false)
        @restart_required, @applied, @published = restart_required, applied, published
        super(message)
      end
    end
    class PreparationError < Error; end
    class RestartRequired < PreparationError; end
    class AnnouncementError < Error; end

    DEPLOYMENT_KEYS = %w[mode bind api_only webui_root executor_socket public_url].freeze
    EDITABLE_KEYS = (Config::KEYS - DEPLOYMENT_KEYS).freeze
    PUBLIC_KEYS = EDITABLE_KEYS

    # The caller holds the home's lifetime lock. Root conversion is one write;
    # each enabled plugin then migrates independently without touching siblings.
    def self.prepare(home, flags: {})
      document = Config.read(home.settings_path)
      version = document.fetch("settings_version", 0)
      unless [0, Config::SETTINGS_VERSION].include?(version)
        raise ConfigurationError, "settings format is newer than this rho"
      end
      if version.zero?
        document = Configuration::SettingsMigration.call(document, home: home)
        # The previous settings format was operator-authored plain text. This
        # conversion adopts the private current format before importing secrets.
        File.chmod(StateFile::PRIVATE_FILE_MODE, home.settings_path) if File.file?(home.settings_path)
        home.write_settings(document)
      end
      config = Config.load(home.settings_path, flags: flags, home: home)
      config.catalog.descriptors.each_value do |descriptor|
        entry = document.fetch("plugins", {}).fetch(descriptor.id, {})
        next unless config.plugin_requested?(descriptor.id)
        next if config.catalog.failures.key?(descriptor.id)
        from = entry.fetch("configuration_version", descriptor.version)
        next if from == descriptor.version

        begin
          resolved = descriptor.migrate(entry.fetch("configuration", {}), from: from)
        rescue ConfigurationError
          # The unchanged version remains a visible plugin error. Core and
          # unrelated enabled plugins can still start and repair this entry.
          next
        end
        entry = entry.merge("configuration_version" => descriptor.version, "configuration" => resolved.overrides)
        document = document.merge("plugins" => document.fetch("plugins").merge(descriptor.id => entry))
        home.write_settings(document)
      end
      document
    end

    def initialize(home:, config:, apply:, validate: ->(_config, _changes) { })
      @home, @config, @apply, @validate = home, config, apply, validate
      @writing = Async::Semaphore.new(1)
    end

    def update(patch, before_save: nil)
      changes = patch.to_h.transform_keys(&:to_s)
      unknown = changes.keys - EDITABLE_KEYS
      raise ConfigurationError, "#{unknown.first} is not an editable agent setting" unless unknown.empty?

      @writing.acquire do
        if changes.key?("workspace") && @config.workspace_override
          raise ConfigurationError, "workspace is fixed by --workspace; remove that launch flag before choosing a default"
        end
        document = Config.read(@home.settings_path).merge(changes)
        publish(document, changes.keys, before_save: before_save)
      end
    end

    def update_plugin(id, operations:, enabled: nil, dependents: [], before_save: nil)
      @writing.acquire do
        document = Config.read(@home.settings_path)
        plugins = document.fetch("plugins", {}).dup
        catalog = Extensions::Catalog.new(home: @home, entries: plugins)
        disabling = enabled == false && operations.empty?
        entry = plugins.fetch(id, {})
        unless disabling && plugins.key?(id)
          descriptor = catalog.fetch(id)
          raise ConfigurationError, catalog.failures.fetch(id) if catalog.failures.key?(id)

          if descriptor.source["kind"] == "package"
            manifest = Packages::Manifest.read(descriptor.directory)
            manifest.validate_dependencies if enabled == true
            unless entry.key?("source")
              entry = entry.merge("source" => descriptor.source, "state_schema" => manifest.state_schema,
                "enabled" => entry.fetch("enabled", false))
            end
          end

          # Disabling a failed or newer plugin preserves its migration input.
          # Editing or enabling it requires the current schema first.
          unless disabling
            from = entry.fetch("configuration_version", descriptor.version)
            raw = descriptor.migrate(entry.fetch("configuration", {}), from: from).overrides
            resolved = descriptor.schema.edit(raw, operations: operations)
            entry = entry.merge("configuration_version" => descriptor.version, "configuration" => resolved.overrides)
          end
        end
        unless enabled.nil?
          unless [true, false].include?(enabled)
            raise ConfigurationError, "plugin enabled must be true or false"
          end
          entry = entry.merge("enabled" => enabled)
        end
        plugins[id] = entry
        if enabled == false
          dependents.each do |dependent|
            catalog.fetch(dependent) unless plugins.key?(dependent)
            plugins[dependent] = plugins.fetch(dependent, {}).merge("enabled" => false)
          end
        end
        candidate = document.merge("plugins" => plugins)
        validate_dependencies(Config.from_hash(candidate, home: @home), changed: [id, *dependents])
        publish(candidate, ["plugins", id, *dependents], before_save: before_save)
      end
    end

    def validate_plugins(config) = validate_dependencies(config)

    def synchronize(&block) = @writing.acquire(&block)

    private

      def validate_dependencies(config, changed: [])
        config.catalog.descriptors.each_value do |descriptor|
          next unless config.plugin_requested?(descriptor.id)

          missing = descriptor.requires.reject { |id| config.plugin_enabled?(id) }
          previous = descriptor.requires.reject { |id| @config.plugin_enabled?(id) }
          if !missing.empty? && (changed.include?(descriptor.id) || missing != previous)
            raise ConfigurationError, "#{descriptor.id} requires enabled plugins: #{missing.join(", ")}"
          end
        end
      end

      def publish(document, changes, before_save:)
        previous = @config.with({})
        document = { "settings_version" => Config::SETTINGS_VERSION, "plugins" => {} }.merge(document)
        values = document.slice(*(changes & Config::KEYS))
        if changes.include?("plugins")
          ids = changes - ["plugins"]
          values["plugins"] = @config.plugins.merge(document.fetch("plugins").slice(*ids))
        end
        candidate = @config.with(values)
        validate_dependencies(candidate, changed: changes - ["plugins"]) if changes.include?("plugins")
        @validate.call(candidate, changes)
        before_save&.call
        @home.write_settings(document)
        @config.apply(candidate)
        begin
          @apply.call(previous, changes)
        rescue AnnouncementError => error
          raise ApplyError.new(error.message, applied: true), cause: nil
        rescue RestartRequired
          raise ApplyError.new("Settings were saved. Restart rho to apply the changes; the current plugins remain active.", restart_required: true), cause: nil
        rescue Rho::Runner::Extensions::PrerequisiteError => error
          raise ApplyError, error.message, cause: nil
        rescue StandardError => error
          raise ApplyError, "Settings were saved, but applying them failed (#{error.class.name}); correct the issue and try saving again.", cause: nil
        end
        @config
      end
  end
end
