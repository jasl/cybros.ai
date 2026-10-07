require "async/semaphore"

module Rho
  class Daemon
    # Connection changes retire only the runtime resources whose credentials changed.

    private

      # Seal the gate, wait for every admitted handler, then the ceremony's
      # own preparation; an aborted stop restores the ordinary lifecycle.
      def begin_stop
        @lineage.begin_stop
        @lineage.quiesce(deadline: STOP_CONTROL_DRAIN_DEADLINE)
        @ceremony.prepare_for_stop
      rescue StandardError
        @lineage.abort_stop
        raise
      end

      # The one place adoption happens; the facts are required because a
      # default read from the slot once adopted `nil, nil` mid-loss. The
      # independent Runner mounts directly, even while the Agent cannot
      # adopt a workspace.
      def adopt_connection(identity:, credentials:, authority_report: nil)
        adoption = publish_member_connection(adopting: credentials) do
          @lineage.adopt(identity: identity, credentials: credentials, authority_report: authority_report)
        end
        retire(adoption.retired)
        publish_phase_change(adoption.from, :active) if adoption.changed
        @server.spawn { mount_runner(credentials, :runner) } if adoption.changed && credentials.runner?
      end

      # THE RUNNER HALF, ADOPTED: the runner-only ceremony on a
      # live agent attaches its OAuth under the monitor — the lineage does
      # not move, its runs and sockets stand — and the `:runner` slot is
      # mounted directly; the maintenance wake is for the workspace, not the
      # runner.
      def adopt_runner(about:, identity:, runner:, authority_report: nil)
        return unless @lineage.adopt_runner(about, identity: identity, runner: runner, authority_report: authority_report)

        log.info("runner.adopted", runner: identity.runner_executor_public_id)
        announce
        @server.spawn { mount_runner(about, :runner) }
      end

      # What every lineage edge leaves the caller to do OUTSIDE the monitor.
      def settle(adoption, phase)
        retire(adoption.retired)
        publish_member_connection if adoption.changed
        publish_phase_change(adoption.from, phase) if adoption.changed
      end

      # Agent loss retires its own resources while an independent Runner
      # stands. Without that second lineage the whole connection is lost.
      def lose_authority(about: nil, unless_stopping: false, report: nil)
        about ||= @lineage.credentials
        if @config.mode == "full" && about&.runner? && !report&.dig(:runner_lost)
          retired = @lineage.lose_agent(about, unless_stopping: unless_stopping, report: report)
          return false if retired.nil?

          retire(retired)
          publish_member_connection
          announce
          return true
        end

        adoption = @lineage.lose(about: about, unless_stopping: unless_stopping, report: report)
        return false if adoption.nil?

        settle(adoption, :disconnected)
        true
      end

      # The runner lineage answered terminally, or `rho disconnect --runner`
      # took it: the runner half drops with its slot and socket; the agent's
      # own run and the lineage stand.
      def lose_runner_authority(about:, unless_stopping: false, identity: nil)
        return false if unless_stopping && @lineage.stopping?

        retired = @lineage.lose_runner(about, identity: identity)
        return false if retired.nil?

        log.warn("runner.authority_lost")
        retire(retired)
        if @lineage.snapshot.observation&.report&.dig(:lost)
          return true if lose_authority(about: about, unless_stopping: unless_stopping)
        end
        announce
        true
      end

      def retire(retired, wait: false)
        retired.runners.each { |runner| stop_runner(runner) }
        cleanup_followers(retired.followers, retired.clients, wait: wait)
      end

      # The retired runs and clients are stopped on their owning reactor;
      # shutdown waits only for that synchronous detach/close scheduling.
      def cleanup_followers(runs, clients, wait: false)
        return if runs.empty? && clients.empty?

        completed = Thread::Queue.new if wait
        @server.spawn do
          begin
            runs.each(&:stop)
          ensure
            begin
              clients.each(&:close)
            ensure
              completed&.push(true)
            end
          end
        end
        return unless completed

        completed.pop(timeout: STOP_CONTROL_DRAIN_DEADLINE) ||
          log.warn("inference_request.cleanup_timeout")
      end

      # Bounded, never killed: a tool thread killed mid-write is how a
      # half-written file happens.
      def stop_runner(runner)
        return if runner.nil?

        runner.stop
      rescue StandardError => error
        log.warn("runner_stop_failed", error_class: error.class.name)
      end

      def transition(phase)
        from = @lineage.transition(phase)
        publish_phase_change(from, phase)
      end

      # The `on_phase` hook is an arbitrary lambda and never runs under the monitor.
      def publish_phase_change(from, phase)
        log.info("daemon.phase", from: from, to: phase) unless phase == from
        announce
        @on_phase&.call(phase)
      end

      # Connection-scoped background workers retire on their owning reactor.
      # Both the ceremony thread and an HTTP handler wait for retirement, so a
      # completed disconnect cannot leave the old worker sending effects.
      # Adoption's pure lineage mutation runs inside the same gate, after old
      # workers retire and before new credentials become visible to their Core
      # requests. Resource cleanup remains with the adoption caller.
      def publish_member_connection(adopting: nil)
        return block_given? ? yield : nil if @loaded.daemon_hooks.none? { |hook| hook.event == :member_connection }

        completed = Thread::Queue.new
        @server.spawn do
          result = error = nil
          @member_connection_gate ||= Async::Semaphore.new(1)
          @member_connection_gate.acquire do
            hooks = @loaded.daemon_hooks.select { |hook| hook.event == :member_connection }
            if adopting && @extension_member_about && !@extension_member_about.equal?(adopting)
              notify_member_connection(hooks, nil)
            end
            result = yield if block_given?
            snapshot = @lineage.snapshot
            about = member_connection_credentials(snapshot)
            next if @extension_member_about.equal?(about)

            connection = about && Extensions::MemberConnection.new(
              user_public_id: snapshot.identity.user_public_id,
              client: @wire.client(credential_provider: about.method(:member_credential).to_proc)
            )
            notify_member_connection(hooks, connection, about: about)
          end
        rescue StandardError => caught
          error = caught
        ensure
          completed.push([result, error])
        end
        result, error = completed.pop
        raise error if error

        result
      end

      def member_connection_credentials(snapshot)
        about = snapshot.credentials
        about unless snapshot.lost || snapshot.observation&.report&.dig(:lost) || !about&.member_plane?
      end

      def notify_member_connection(hooks, connection, about: nil)
        @extension_member_about = about
        hooks.each do |hook|
          notify_extension(hook.extension, "member_connection") { hook.call(connection) }
        end
      end

      # The member plane may be mid-rotation or terminally lost; the
      # authority probe diagnoses that, so a caller just skips this cycle.
      def member_credential_for(about)
        about.member_credential
      rescue CybrosAgent::Error => error
        log.warn("workspace.member_plane_unavailable", error: CybrosAgent::Redaction.call(error.message))
        nil
      end

      # The member plane as a tool reaches it: the client and
      # the adopted workspace, or nil while there is no adopted workspace or
      # no member credential — a refusal here is a tool's error text, so the
      # Refusal is not handed on.
      def member_plane_handle(host_public_id: nil, require_workspace: true, workspace_public_id: nil)
        return nil if @context.nil?

        handle = @context.member_plane(host_public_id: host_public_id, require_workspace: require_workspace,
          workspace_public_id: workspace_public_id) do |client, selected_workspace|
          Extensions::MemberPlane.new(client: client, workspace_public_id: selected_workspace)
        end
        handle if handle in Extensions::MemberPlane
      end

      # The executor plane's twin, for the announcement: a lineage
      # with no live transport credential announces nothing and says so.
      def executor_credential_for(about)
        about.executor_credential
      rescue CybrosAgent::Error => error
        log.warn("workspace.executor_plane_unavailable", error: CybrosAgent::Redaction.call(error.message))
        nil
      end

      # The runner lineage's, for the runner address.
      def runner_credential_for(about)
        about.runner_credential
      rescue CybrosAgent::Error => error
        log.warn("workspace.runner_plane_unavailable", error: CybrosAgent::Redaction.call(error.message))
        nil
      end
  end
end
