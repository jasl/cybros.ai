module Rho
  class Daemon
    private

      def validate_settings(config, changes)
        self.class.verify_bind(@bind, transport_assertion: @transport_assertion,
          access_passphrase: config.access_passphrase)
        if changes.include?("tools_root") && config.tools_root && !File.directory?(config.tools_root)
          raise ConfigurationError, "tools_root must name an existing directory"
        end
        Adaptations.load(config, home: @home) unless runner_mode?
      end

      # Each registration retains its own worker state until its configuration
      # changes. Rebuilding the combined registry does not restart those owners.
      def apply_settings(previous, changes)
        @context.clear_environment_override if changes.include?("tools_root")
        @access_lock = AccessLock.build(@config.access_passphrase) if changes.include?("access_passphrase")
        @host = @host.with(checkpoints: checkpoints_member)
        old = @loaded
        sources = Extensions.sources(@home, @config)
        reloaded = changed_extensions(previous, changes)
        wanted = old.registrations.select do |api|
          if api.source == "<built-in>"
            @extensions.any? { |mod| Rho::Runner::Extensions::Loader.extension_name_of(mod) == api.extension_name }
          else
            sources.paths.include?(api.source) || sources.gems.any? { |feature| api.source == "gem:#{feature}" }
          end
        end
        reusable = wanted.reject { |api| reloaded.include?(api.extension_name) }
        removed = old.registrations - reusable
        removed.reverse_each do |api|
          next if wanted.include?(api) && %w[rho.mcp rho.acp-client].include?(api.extension_name)

          api.lifecycle.select { |hook| hook.event == :shutdown }.reverse_each { |hook| hook.handler.call }
        end
        @loaded = Extensions.load(host: @host, extensions: @extensions, gems: sources.gems,
          paths: sources.paths, log: log, reuse: reusable)
        @webui = webui
        @context.configure(host: @host, loaded: @loaded, page: page?)
        @environments.configure(config: @config, registry: @loaded.registry.serving(:runner),
          agent_registry: @loaded.registry.serving(:agent), registrar: @loaded.conversation_servers,
          served: @loaded.registry, checkpoints: !@host.checkpoints.nil?)
        Lineage::SLOTS.each do |slot|
          @lineage.runner(slot)&.configure(hooks: registry_for(slot).hooks)
        end
        @routes = Routes.new(routes: core_routes + @loaded.routes, context: @context,
          lineage: @lineage, bearer: @bearer)
        @server.configure(routes: @routes.table, static_root: @webui)
        about = @lineage.credentials
        begin
          @maintenance.refresh_workspace(about) if changes.include?("workspace")
          Lineage::SLOTS.each do |slot|
            credential = about && slot_credential_for(about, slot)
            announce_slot(credential, slot) if credential && @lineage.runner(slot)
          end
          outcome = @loops&.configure(config: @config, loaded: @loaded)
        ensure
          # These registrations are already published locally. A refused remote
          # declaration must not leave reusable owners that were never started.
          start_configured_extensions(@loaded.registrations - reusable)
          @loaded.daemon_hooks.each do |hook|
            hook.handler.call(@config) if hook.event == :configuration_change
          end
        end
        if outcome in Loops::Refused
          raise ConfigurationError, "The platform refused the updated agent configuration (#{outcome.code})"
        end
        log.info("settings.applied", keys: changes)
      end

      def changed_extensions(previous, changes)
        names = []
        if (changes & %w[image_model default_model adaptations adaptations_dir]).any?
          names << "rho.images"
        end
        if changes.include?("checkpoints") || changes.include?("tools_root")
          names << "rho.checkpoints"
        end
        names << "rho.mcp" if changes.include?("mcp_servers")
        names << "rho.acp-client" if changes.include?("acp_agents")
        names << "rho.web_tools" if changes.include?("web")
        if previous.extensions.include?("rho/ingress-telegram") != @config.extensions.include?("rho/ingress-telegram")
          names << "rho.ingress_telegram"
        end
        names
      end

      def start_configured_extensions(registrations)
        registrations.each do |api|
          api.lifecycle.select { |hook| hook.event == :startup }.each { |hook| hook.handler.call }
          api.background_tasks.each do |task|
            @server.spawn { notify_extension(task.extension, "background:#{task.name}") { task.handler.call } }
          end
          about = @extension_member_about
          if about
            connection = Extensions::MemberConnection.new(user_public_id: @lineage.identity.user_public_id,
              client: @wire.client(credential_provider: about.method(:member_credential).to_proc))
            api.daemon_hooks.each do |hook|
              hook.handler.call(connection) if hook.event == :member_connection
            end
          end
        end
      end
  end
end
