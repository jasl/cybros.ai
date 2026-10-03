module Rho
  class Daemon
    # Runtime placement and clients for the daemon's two executor slots.

    private

      # Built outside the lock between a reservation and an install, so two
      # edges cannot race two runners onto one slot. EACH SLOT IS BUILT FROM ITS OWN CREDENTIAL: the `:runner` slot from the runner lineage's
      # transport credential with the environment tools and the root's
      # environment document, the `:agent_runner` slot from the agent's
      # transport credential with the agent's own tools, one worker, no
      # environment. A slot whose credential is unavailable places no
      # runner — a dark one would only log sweep failures — and gives its
      # reservation back. Answers the runner it installed and started, or nil.
      def mount_runner(about, slot)
        return unless @lineage.reserve_runner(about, slot: slot)

        credential = slot_credential_for(about, slot)
        if credential.nil?
          @lineage.release_runner(about, slot: slot)
          log.warn("runner.not_placed", slot: slot, reason: "#{ExecutorPlane::ADDRESSES.fetch(slot)} plane unavailable")
          return
        end

        # PLACEMENT ZERO's env is the slot's announced one:
        # a claim resolves its own placement on the worker.
        env = @environments.zero.env
        runner = build_runner(about, registry_for(slot), slot)
        unless @lineage.install_runner(about, runner, env, slot: slot)
          stop_runner(runner)
          return
        end

        announce_slot(credential, slot)
        @server.spawn { runner.follow }
        @server.spawn { @executor_plane.nudge_stream(about, slot) } if @config.executor_socket
        runner
      end

      # SYNCHRONOUS at placement, before the runner follows: one
      # bounded PUT under the SDK's request timeout, so the address has
      # announced its tools before any turn's call can be addressed to it;
      # again on `reannounce` after a moved default root, and for the
      # AGENT slot after a moved server set. The environment document is
      # the runner address's (the DEFAULT root's, with this daemon's
      # boot); the documents are EACH address's own projection: the runner's the default root's skills beside its
      # stdio servers' prompts, the agent's whatever its extensions
      # announce. THE AGENT SLOT'S LIST is
      # the registry's entries ∪ every anchor's editor servers, a name
      # once — the runner slot's is the registry's alone.
      def announce_slot(credential, slot)
        registry = registry_for(slot)
        @executor_plane.announce_tools(credential, registry: registry,
          environment: (@executor_plane.environment_document(registry) if slot == :runner),
          documents: @executor_plane.documents(registry), slot: slot,
          extras: (slot == :agent_runner ? @environments.servers.announcement : []))
      end

      def registry_for(slot) = @loaded.registry.serving(slot == :runner ? :runner : :agent)

      def slot_credential_for(about, slot)
        slot == :runner ? runner_credential_for(about) : executor_credential_for(about)
      end

      # The inbox is per executor, so no workspace reaches the runner. The
      # agent's own loop runs one worker; the claim line
      # names the address it serves. THE TOOLSETS RESOLVE PER CLAIM: the runner slot's by the row's conversation through the
      # daemon's tables — the received binding, the record, the walk, else
      # zero; the agent slot's over zero's env with its own tools, resolving
      # the record for its ANCHOR's editor servers.
      def build_runner(about, registry, slot)
        oauth = slot == :runner ? about.runner : about.agent
        Rho::Runner.new(
          executor: @wire.executor_client(credential_provider: oauth.method(:executor_credential).to_proc),
          toolsets: toolsets_for(registry, slot),
          hooks: registry.hooks, log: log.tagged(address: ExecutorPlane::ADDRESSES.fetch(slot)),
          pool: (Rho::Runner::Pool.new(worker_threads: 1) if slot == :agent_runner)
        )
      end

      def toolsets_for(registry, slot)
        slot == :runner ? @environments.toolsets : @environments.agent_toolsets(registry)
      end
  end
end
