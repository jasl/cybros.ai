module Rho
  module Extensions
    # Core recovery routes remain present when every optional owner is disabled.
    module Manager
      def self.register(api)
        Rho::Settings::Control.register(api)
        api.register_route("GET", "/extensions") { |_request, ctx| [200, ctx.plugin_inventory] }
        api.register_route("GET", "/extensions/packages") do |_request, ctx|
          result = ctx.manage_packages(action: "list")
          (result in Daemon::Refusal) ? result : [200, result]
        end
        api.register_route("POST", "/extensions/packages") do |request, ctx|
          fields = ControlServer.json_body(request).slice("action", "name", "version", "path", "configuration")
          result = ctx.manage_packages(**fields.transform_keys(&:to_sym))
          (result in Daemon::Refusal) ? result : [200, result]
        end
        (api.host.config.catalog.descriptors.keys | api.host.config.plugins.keys).each do |id|
          api.register_route("PATCH", "/extensions/#{id}/configuration") do |request, ctx|
            fields = ControlServer.json_body(request)
            save(ctx, id, operations: fields.fetch("operations"), enabled: fields["enabled"])
          end
          { "enable" => true, "disable" => false }.each do |action, enabled|
            api.register_route("POST", "/extensions/#{id}/#{action}") do |request, ctx|
              fields = ControlServer.json_body(request)
              save(ctx, id, operations: [], enabled: enabled, dependents: fields.fetch("dependents", []))
            end
          end
        end
      end

      def self.document(home:, config:, loaded:)
        saved = Config.load(home.settings_path, flags: { mode: config.mode }, home: home)
        runtime_failures = loaded.failures.map do |failure|
          descriptor = config.catalog.descriptors.values.find do |candidate|
            candidate.source.fetch("kind") != "builtin" && runtime_source(candidate) == failure.source
          end
          { id: descriptor&.id || failure.source, source: failure.source,
            message: failure.public_message }
        end
        rows = (saved.catalog.descriptors.keys | saved.plugins.keys).map do |id|
          plugin_row(id, saved: saved, config: config, loaded: loaded, failures: runtime_failures)
        end
        failures = saved.catalog.failures.map { |id, message| { id: id, message: message } } + runtime_failures
        { plugins: rows, failures: failures, recovery_command: "rho extensions enable rho.webui" }
      end

      def self.plugin_row(id, saved:, config:, loaded:, failures:)
        descriptor = saved.catalog.descriptors[id]
        active_descriptor = config.catalog.descriptors[id]
        api = loaded.registrations.find { |owner| owner.extension_name == id }
        selected = descriptor&.source&.fetch("kind") != "package" || saved.plugins.dig(id, "source") == descriptor.source
        requested = selected && saved.plugins.fetch(id, {}).fetch("enabled", descriptor&.default_enabled || false) == true
        source = descriptor&.source || saved.plugins.fetch(id, {}).fetch("source", {})
        active = !api.nil?
        issues = failures.select { |failure| failure.fetch(:id) == id }.map { |failure| failure.fetch(:message) }
        issues << saved.plugin_errors[id] if saved.plugin_errors.key?(id)
        readiness = readiness(api)
        issues.concat(readiness.fetch(:issues))
        configuration = if descriptor
          issues << "Unavailable in #{saved.mode} mode" unless descriptor.modes.include?(saved.mode)
          required = saved.plugin_resolution(id).diagnostics.select { |item| item.reason == "required" }
          issues << "Required configuration fields are missing" unless required.empty?
          descriptor.schema.view(saved.plugin_resolution(id)).to_h
        else
          issues << "Plugin description is unavailable; repair or reinstall it before enabling or configuring it."
          { schema: { "type" => "object", "properties" => {} }, overrides: {}, value: {}, diagnostics: [], secrets: [] }
        end
        different = requested != active || (api &&
          (source != active_descriptor&.source || !descriptor || api.configuration != saved.plugin_configuration(id)))
        if different && active
          issues << "Saved changes have not been applied; the previous plugin instance is still running."
        end
        {
          id: id, name: descriptor&.name || id, description: descriptor&.description || "",
          source: source, version: source["version"], active_source: active ? active_descriptor&.source : nil,
          enabled: requested, default_enabled: descriptor&.default_enabled || false, requires: descriptor&.requires || [],
          configurable: !descriptor.nil?, active: active, restart_required: !!(different && api&.restart_only?),
          readiness: { ready: active && readiness.fetch(:ready) && issues.empty?, issues: issues.uniq },
          configuration: configuration,
          capabilities: {
            tools: loaded.registry.entries.select { |entry| entry.extension == id }.map(&:name),
            commands: loaded.commands.select { |command| command.extension == id }.map(&:name),
          },
        }
      end

      def self.readiness(api)
        return { ready: false, issues: [] } unless api

        status = api.readiness
        { ready: status.fetch(:ready), issues: status.fetch(:issues).to_a }
      rescue StandardError => error
        { ready: false, issues: ["Plugin status could not be read (#{error.class.name})."] }
      end

      def self.runtime_source(descriptor)
        case descriptor.source.fetch("kind")
        when "builtin" then "<built-in>"
        when "gem" then "gem:#{descriptor.source.fetch("feature")}"
        when "path" then descriptor.source.fetch("path")
        when "package" then File.join(descriptor.directory, "extension.rb")
        else nil
        end
      end

      def self.save(ctx, id, **options)
        ctx.configure_plugin(id, **options)
        plugin = ctx.plugin_inventory.fetch(:plugins).find { |row| row.fetch(:id) == id }
        [200, { saved: true, applied: true, published: true, restart_required: false,
          diagnostics: plugin ? plugin.fetch(:configuration).fetch(:diagnostics) : [], plugin: plugin }]
      rescue ConfigurationError, KeyError, NoMethodError, TypeError => error
        Daemon::Refusal.new(status: 422, code: "plugin_configuration_invalid", message: error.message,
          extra: { saved: false, applied: false })
      rescue Rho::Settings::ApplyError => error
        plugin = ctx.plugin_inventory.fetch(:plugins).find { |row| row.fetch(:id) == id }
        facts = { saved: true, applied: error.applied, published: error.published,
          restart_required: error.restart_required, plugin: plugin, message: error.message }
        if error.restart_required
          [200, facts]
        else
          Daemon::Refusal.new(status: 503, code: "plugin_configuration_unapplied", message: error.message,
            extra: facts.except(:message))
        end
      rescue StateFile::PublishedError => error
        Daemon::Refusal.new(status: 503, code: "settings_durability_uncertain", message: error.message,
          extra: { saved: true, published: true, applied: false })
      end
    end
  end
end
