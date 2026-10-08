module Rho
  class Daemon
    private

      def validate_settings(config, changes)
        self.class.verify_bind(@bind, transport_assertion: @transport_assertion)
        if changes.include?("tools_root") && config.tools_root && !File.directory?(config.tools_root)
          raise ConfigurationError, "tools_root must name an existing directory"
        end
        Adaptations.load(config, home: @home) unless runner_mode?
      end

      def apply_settings(previous, changes)
        replace_extensions(reloaded: changed_extensions(previous, changes))
        @context.clear_environment_override if changes.include?("tools_root")
        begin
          publish_extension_announcements(changes)
        rescue Rho::ConfigurationError, CybrosAgent::Error => error
          raise Settings::AnnouncementError, "Settings were applied locally, but platform announcement failed (#{error.class.name}).", cause: nil
        end
        log.info("settings.applied", keys: changes)
      rescue Settings::PreparationError, Rho::Runner::Extensions::PrerequisiteError
        @config.apply(previous)
        raise
      end

      # OAuth changes connection state without changing settings. Use the same
      # serialized publication path, preserving every unrelated registration.
      def refresh_extension(name)
        @settings.synchronize do
          unless @loaded.registrations.any? { |api| api.extension_name == name }
            raise ConfigurationError, "#{name} is not loaded"
          end
          retired = replace_extensions(reloaded: [name])
          publish_extension_announcements([])
          { "refreshed" => name,
            "cleanup_pending" => retired.reject { |api| api.resources.disposed? }.map(&:extension_name),
            "failures" => retired.flat_map do |api|
              api.resources.failures.map { |error| { "extension" => api.extension_name, "error_class" => error } }
            end }
        end
      end

      def manage_packages(action:, name: nil, version: nil, path: nil, configuration: nil)
        @settings.synchronize do
          packages = Rho::Packages.new(home: @home)
          case action
          when "list"
            packages.list.tap do |document|
              document.fetch(:packages).each do |row|
                row[:active] = active_package_version(row.fetch(:id), row.fetch(:name)) == row.fetch(:version)
              end
            end
          when "install"
            outcome = packages.install(path: path)
            @config.apply(@config.with({}))
            @routes = Routes.new(routes: core_routes + @loaded.routes, context: @context,
              lineage: @lineage, bearer: @bearer, browser_login: @browser_login)
            @server.configure(routes: @routes.table, static_root: @webui)
            outcome.merge(active: active_package_version(outcome.fetch(:id), outcome.fetch(:name)) == outcome.fetch(:version))
          when "check" then packages.check(name: name, version: version)
          when "activate", "disable", "rollback"
            options = { name: name }
            options.merge!(version: version, configuration: configuration) if action == "activate"
            outcome = packages.public_send(action, **options) do |_sources, persist, document|
              previous = @config.with({})
              id, entry = document.fetch("plugins").find do |_id, row|
                source = row.fetch("source", {})
                source["kind"] == "package" && source["name"] == name
              end
              candidate = @config.with({ "plugins" => @config.plugins.merge(id => entry) })
              sources = packages.sources(plugins: candidate.plugins)
              @settings.validate_plugins(candidate)
              persist.call
              @config.apply(candidate)
              begin
                changed = @loaded.registrations.filter_map do |api|
                  package = sources.find { |source| source.path == api.source }
                  api.extension_name if package && package.configuration != api.configuration
                end
                changed << id if failed_extension?(id)
                retired = replace_extensions(reloaded: changed, managed: sources)
              rescue Settings::PreparationError, Rho::Runner::Extensions::PrerequisiteError => error
                @config.apply(previous)
                warning = if error in Rho::Runner::Extensions::PrerequisiteError
                  error.message
                else
                  "Package selection was saved but could not be applied (#{error.class.name})."
                end
                next({ saved: true, applied: false,
                  restart_required: (error in Settings::RestartRequired),
                  warning: warning })
              end
              outcome = { saved: true, applied: true, restart_required: false,
                cleanup_pending: retired.reject { |api| api.resources.disposed? }.map(&:extension_name),
                failures: retired.flat_map do |api|
                  api.resources.failures.map { |error| { extension: api.extension_name, error_class: error } }
                end }
              begin
                publish_extension_announcements([])
                outcome[:published] = true
              rescue Rho::ConfigurationError, CybrosAgent::Error => error
                outcome[:published] = false
                outcome[:warning] = "Applied locally; platform announcement failed (#{error.class.name})."
                log.warn("extension_announcement_failed", error_class: error.class.name)
              end
              outcome
            end
            outcome.merge(active: active_package_version(outcome.fetch(:id), outcome.fetch(:name)))
          else
            raise ConfigurationError, "Unknown extension package action #{action}"
          end
        end
      rescue Rho::ConfigurationError, Rho::StateError, Settings::PreparationError => error
        Refusal.new(status: 422, code: "extension_package_refused", message: error.message)
      end

      def active_package_version(id, name)
        source = @loaded.registrations.find { |api| api.extension_name == id }&.source
        directory = source && File.dirname(source)
        if directory && File.dirname(directory) == File.join(@home.extensions_root, "managed", name)
          File.basename(directory)
        end
      end

      def replace_extensions(reloaded:, managed: Rho::Packages.new(home: @home).sources(plugins: @config.plugins))
        old = @loaded
        host = @host.with(checkpoints: checkpoints_member)
        sources = Extensions.sources(@home, @config, managed: managed)
        reusable = old.registrations.select do |api|
          wanted = if api.source == "<built-in>"
            Extensions.selected_builtins(@config, @extensions).any? { |mod| Rho::Runner::Extensions::Loader.extension_name_of(mod) == api.extension_name }
          else
            sources.paths.include?(api.source) || sources.gems.any? { |feature| api.source == "gem:#{feature}" }
          end
          wanted && !reloaded.include?(api.extension_name)
        end
        exclusive = (old.registrations - reusable).select(&:restart_only?)
        unless exclusive.empty?
          raise Settings::RestartRequired, "Restart required to replace or remove #{exclusive.map(&:extension_name).join(", ")}"
        end
        # Failed optional factories remain visible, but unrelated changes do
        # not retry them. An explicit edit or enable names the owner to retry.
        deferred = old.failures.reject { |failure| reloaded.include?(extension_id_for_failure(failure)) }
        skipped = deferred.map(&:source) - reusable.map(&:source)
        prepared_sources = sources.with(paths: sources.paths - skipped,
          gems: sources.gems.reject { |feature| skipped.include?("gem:#{feature}") })
        candidate = prepare_extensions(host, prepared_sources, reusable).with(failures: deferred)
        added = candidate.registrations - reusable
        begin
          routes = Routes.new(routes: core_routes + candidate.routes, context: @context,
            lineage: @lineage, bearer: @bearer, browser_login: @browser_login)
          page = webui(candidate)
          added.each do |api|
            start_registration(api)
          rescue StandardError, ScriptError => error
            failure = Rho::Runner::Extensions::Loader::Failure.new(
              source: api.source, error_class: error.class.name, message: error.message)
            @loaded.failures.replace((@loaded.failures + [failure]).reverse.uniq(&:source).reverse)
            raise
          end
          yield if block_given?
        rescue StandardError, ScriptError => error
          added.reverse_each { |api| api.resources.retire }
          raise if error in Rho::Runner::Extensions::PrerequisiteError

          raise Settings::PreparationError, "Extension preparation failed (#{error.class.name}): #{error.message}"
        end

        # Local publication precedes remote announcements. A remote refusal
        # leaves this ready set mounted and an explicit retry announces it again.
        retired = old.registrations - reusable
        # Connection callbacks and owner replacement share one gate: a queued
        # adoption reads the published owners, and disconnect drains their work.
        @member_connection_gate ||= Async::Semaphore.new(1)
        @member_connection_gate.acquire do
          publish_extensions(host: host, loaded: candidate, routes: routes, page: page)
          retired.reverse_each { |api| api.resources.retire }
          added.each { |api| run_registration(api) }
        end
        retired
      end

      def publish_extensions(host:, loaded:, routes:, page:)
        @host, @loaded, @routes, @webui = host, loaded, routes, page
        @context.configure(host: @host, loaded: @loaded, page: page?)
        @environments.configure(config: @config, registry: @loaded.registry.serving(:runner),
          agent_registry: @loaded.registry.serving(:agent), registrar: @loaded.conversation_servers,
          served: @loaded.registry, checkpoints: !@host.checkpoints.nil?)
        Lineage::SLOTS.each { |slot| @lineage.runner(slot)&.configure(hooks: registry_for(slot).hooks) }
        @server.configure(routes: @routes.table, static_root: @webui)
      end

      def prepare_extensions(host, sources, reusable)
        candidate = Extensions.load(host: host, extensions: Extensions.selected_builtins(@config, @extensions), gems: sources.gems,
          paths: sources.paths, managed: sources.managed, log: log, reuse: reusable)
        if candidate.failures.any?
          (candidate.registrations - reusable).reverse_each { |api| api.resources.retire }
          @loaded.failures.replace((@loaded.failures + candidate.failures).reverse.uniq(&:source).reverse)
          if candidate.failures.any?(&:prerequisite?)
            raise Rho::Runner::Extensions::PrerequisiteError, candidate.failures.map(&:public_message).join("; ")
          end
          raise Settings::PreparationError, candidate.failures.map(&:message).join("; ")
        end
        candidate
      rescue Rho::Runner::Extensions::RegistrationError => error
        raise if error in Rho::Runner::Extensions::PrerequisiteError

        raise Settings::PreparationError, error.message
      end

      def publish_extension_announcements(changes)
        about = @lineage.credentials
        begin
          @maintenance.refresh_workspace(about) if changes.include?("workspace")
          Lineage::SLOTS.each do |slot|
            credential = about && slot_credential_for(about, slot)
            announce_slot(credential, slot) if credential && @lineage.runner(slot)
          end
          outcome = @host_followers&.configure(config: @config, loaded: @loaded)
        ensure
          @loaded.daemon_hooks.each do |hook|
            if hook.event == :configuration_change
              notify_extension(hook.extension, "configuration_change") { hook.call(@config) }
            end
          end
        end
        if outcome in HostFollowers::Refused
          raise ConfigurationError, "The platform refused the updated agent configuration (#{outcome.code})"
        end
      end

      def changed_extensions(previous, changes)
        names = if changes.include?("plugins")
          (changes - ["plugins"]).select do |id|
            !previous.catalog.descriptors.key?(id) || !@config.catalog.descriptors.key?(id) ||
              previous.plugin_configuration(id) != @config.plugin_configuration(id) || failed_extension?(id)
          end
        else
          []
        end
        names << "rho.compaction" if changes.include?("default_model")
        names << "rho.images" if (changes & %w[default_model adaptations adaptations_dir]).any?
        names << "rho.checkpoints" if changes.include?("tools_root")
        names
      end

      def failed_extension?(id)
        @loaded.failures.any? { |failure| extension_id_for_failure(failure) == id }
      end

      def extension_id_for_failure(failure)
        @config.catalog.descriptors.values.find do |descriptor|
          next false if descriptor.source.fetch("kind") == "builtin"

          source = Extensions::Manager.runtime_source(descriptor)
          source == failure.source || (descriptor.source.fetch("kind") == "package" &&
            File.dirname(File.dirname(source)) == File.dirname(File.dirname(failure.source)))
        end&.id
      end

      def start_registration(api)
        api.resources.dispatch = ->(&cleanup) { @server.spawn(&cleanup) }
        api.lifecycle.select { |hook| hook.event == :startup }.each { |hook| hook.handler.call }
      end

      def run_registration(api, member_connection: true)
        api.background_tasks.each do |task|
          @server.spawn do
            worker = Async::Task.current
            begin
              api.resources.own(on_retire: true) { worker.stop unless worker.finished? }
              notify_extension(task.extension, "background:#{task.name}") { task.handler.call }
            rescue Rho::Runner::Extensions::RegistrationError
              # A queued start can arrive after its owner was already retired.
              nil
            end
          end
        end
        hooks = api.daemon_hooks.select { |hook| hook.event == :member_connection }
        if member_connection && !hooks.empty?
          snapshot = @lineage.snapshot
          about = member_connection_credentials(snapshot)
          if about
            connection = Extensions::MemberConnection.new(user_public_id: snapshot.identity.user_public_id,
              client: @wire.client(credential_provider: about.method(:member_credential).to_proc))
            hooks.each do |hook|
              notify_extension(hook.extension, "member_connection") { hook.call(connection) }
            end
          end
        end
      end
  end
end
