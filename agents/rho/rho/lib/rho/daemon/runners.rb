module Rho
  class Daemon
    # One inbox and transport owner; role-specific toolsets share admission capacity.

    private

      def mount_runner(about, slot)
        return unless @lineage.reserve_runner(about, slot: slot)

        owner = about.agent || about.runner
        credential = owner && executor_credential_for(owner)
        if credential.nil?
          @lineage.release_runner(about, slot: slot)
          log.warn("runner.not_placed", reason: "executor plane unavailable")
          return
        end

        roles = execution_roles
        runner = Rho::Runner.new(
          executor: @wire.executor_client(credential_provider: owner.method(:executor_credential).to_proc),
          toolsets: roles.values.first.toolsets, roles: roles,
          admission: (@runner_admission ||= Rho::Runner::Admission.new), log: log.tagged(address: "executor")
        )
        unless @lineage.install_runner(about, runner, @environments.zero.env, slot: slot)
          stop_runner(runner)
          return
        end

        announce_slot(credential, slot)
        @server.spawn { runner.follow }
        @server.spawn { @executor_plane.nudge_stream(about, slot) } if @config.executor_socket
        runner
      end

      # Every update publishes the complete map from the current registries.
      def announce_slot(credential, _slot)
        services = service_registries.to_h do |role, registry|
          [role, {
            "tools" => RunDeclaration.announcement(registry: registry,
              extras: (role == "agent" ? @environments.servers.announcement : [])),
            "documents" => @executor_plane.documents(registry),
            "environment" => (role == "runner" ? @executor_plane.environment_document(registry) : {}),
          }]
        end
        @executor_plane.announce_services(credential, services: services)
      end

      def service_registries
        roles = {}
        roles["agent"] = @loaded.registry.serving(:agent) unless @config.mode == "runner"
        roles["runner"] = @loaded.registry.serving(:runner) unless @config.mode == "agent"
        roles
      end

      def execution_roles
        service_registries.to_h do |role, registry|
          toolsets = role == "runner" ? @environments.toolsets : @environments.agent_toolsets(registry)
          [role, Rho::Runner::Service.new(toolsets: toolsets, hooks: registry.hooks)]
        end
      end

      def slot_credential_for(about, _slot)
        executor_credential_for(about.agent || about.runner)
      end
  end
end
