module Rho
  class Daemon
    # One inbox and transport owner; role-specific toolsets share admission capacity.

    private

      def mount_runner(about)
        return unless @lineage.reserve_runner(about)

        credential = executor_credential_for(about)
        if credential.nil?
          @lineage.release_runner(about)
          log.warn("runner.not_placed", reason: "executor plane unavailable")
          return
        end

        roles = execution_roles
        runner = Rho::Env::Executor.new(
          executor: @wire.executor_client(credential_provider: about.method(:executor_credential).to_proc),
          toolsets: roles.values.first.toolsets, roles: roles,
          admission: (@runner_admission ||= Rho::Env::Admission.new), log: log.tagged(address: "executor")
        )
        unless @lineage.install_runner(about, runner)
          stop_runner(runner)
          return
        end

        announce_services(credential)
        @server.spawn { runner.follow }
        @server.spawn { @executor_plane.nudge_stream(about) } if @config.executor_socket
        runner
      end

      # Every update publishes the complete map from the current registries.
      def announce_services(credential)
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
        { "agent" => @loaded.registry.serving(:agent), "runner" => @loaded.registry.serving(:runner) }
      end

      def execution_roles
        service_registries.to_h do |role, registry|
          toolsets = role == "runner" ? @environments.toolsets : @environments.agent_toolsets(registry)
          [role, Rho::Env::Executor::Service.new(toolsets: toolsets, hooks: registry.hooks)]
        end
      end
  end
end
