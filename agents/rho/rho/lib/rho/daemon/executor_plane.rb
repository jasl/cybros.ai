module Rho
  class Daemon
    # Whole-service announcement and the single executor inbox subscription.
    class ExecutorPlane
      # The runner's cable: ONE channel keyed by the executor the
      # transport bearer names, no params; `work_available` names a kind, a
      # run, a key and a tool name, `work_canceled` a run and a key.
      EXECUTOR_INBOX_CHANNEL = "AgentAPI::V1::ExecutorInboxChannel".freeze
      WORK_AVAILABLE = "work_available".freeze
      WORK_CANCELED = "work_canceled".freeze
      TOOL_CALL_KIND = "tool_call".freeze
      ASK_KIND = "ask".freeze
      APPROVAL_KIND = "approval".freeze
      RECONNECT_SECONDS = 5.0

      # `booted_at` is the daemon's boot
      # instant, announced in the runner address's opaque environment
      # document as the process-life key a host elsewhere re-asserts on.
      def initialize(wire:, lineage:, context:, log:, booted_at: nil)
        @wire = wire
        @lineage = lineage
        @context = context
        @log = log
        @booted_at = booted_at
        @announced = {}
      end

      # How many tools each address's last announcement landed; nil when it
      # failed or never ran — the fact `rho runner` shows beside the tools
      # that loaded.
      def announced = @announced.dup

      def announce_services(credential, services:)
        @wire.executor_client(credential).announce(services: services)
        @announced = services.transform_values { |service| service.fetch("tools").length }
        @announced.each do |role, count|
          @log.info("executor.announced", tools: count, role: role, documents: services.fetch(role).fetch("documents").length)
        end
      rescue CybrosAgent::Error => error
        @announced = services.transform_values { nil }
        @log.warn("executor.announcement_failed", error_class: error.class.name,
          code: error.code, error: CybrosAgent::Redaction.call(error.message))
      end

      # The DEFAULT root's environment document, as the runner address
      # announces it, with this daemon's boot instant.
      def environment_document(registry)
        RunDeclaration.environment_document(registry: registry, environment: root_environment, booted_at: @booted_at)
      end

      # The address's documents over the root's environment — the runner's
      # skills beside its environment document, the
      # agent's extension-announced ones.
      def documents(registry)
        RunDeclaration.documents(registry: registry, environment: root_environment)
      end

      # The lineage owns the client; this listener owns its subscription.
      # Recover transient losses on that same client, but never reopen a
      # retired slot. Ordinary work admission still has the HTTP sweep.
      def nudge_stream(about)
        client = @lineage.executor_realtime_for(about)
        return if client.nil? || client.connected?

        while listening?(client)
          begin
            consume_nudges(client)
            break
          rescue CybrosAgent::Realtime::ConnectionLostError, CybrosAgent::TransportError => error
            log_stream_end(error)
          end
          sleep(RECONNECT_SECONDS) if listening?(client)
        end
      rescue StandardError => error
        log_stream_end(error)
      end

      private

        def listening?(client)
          !@lineage.stopping? && @lineage.executor_realtime.equal?(client)
        end

        def log_stream_end(error)
          @log.warn("executor_nudge_stream_ended", address: "executor", error_class: error.class.name,
            error: CybrosAgent::Redaction.call(error.message))
        end

        def consume_nudges(client)
          client.connect unless client.connected?
          subscription = client.subscribe(channel: EXECUTOR_INBOX_CHANNEL, params: {})
          @lineage.runner&.wake
          subscription.each do |message|
            break unless listening?(client)

            event = Hash.try_convert(Hash.try_convert(message)&.fetch("event", nil))
            next unless event

            case event["type"]
            when WORK_AVAILABLE
              # One fiber per nudge: `nudged` waits for the tool's answer, and
              # running it here starved the next nudge until the current tool
              # finished. The pool declines when full, so this cannot pile up.
              # An `ask` kind is the agent's row, and
              # an `approval` kind a call held for a person —
              # neither the runner's: each is noted — the daemon's ask or
              # approval notice — and never dispatched; the inbox is the
              # level-triggered truth `rho status` and `GET /asks` read, and
              # the follower's ASKING line stays the person's live signal. A
              # kind this version does not know is left to the sweep, which
              # carries it.
              case event["kind"]
              when TOOL_CALL_KIND then @context.spawn { dispatch_nudge(event) }
              when ASK_KIND
                @log.info("executor.ask_available", run_public_id: event["run_public_id"], task: event["task_key"])
              when APPROVAL_KIND
                @log.info("executor.approval_available", run_public_id: event["run_public_id"], task: event["task_key"])
              else nil
              end
            when WORK_CANCELED
              # Cheap and inline: the running context is found by run and key,
              # cancelled cooperatively on every placed runner; nothing waits
              # on the answer.
              @lineage.runner&.cancel(run_public_id: event["run_public_id"], task_key: event["task_key"])
            else
              # A frame this version does not know: the row is the fact and
              # the sweep will read it.
              nil
            end
          end
          @log.info("executor_nudge_stream_ended", address: "executor", reason: "closed")
        ensure
          subscription&.unsubscribe
        end

        def root_environment = Rho::Env::Environment.local(root: @context.tool_env.root)

        # The runner of the moment, not the stream's: `rho env` rebuilds it,
        # and a captured one handed every nudge to a stopped runner (the
        # signature is `nudged: 0` beside a rising `swept`).
        def dispatch_nudge(event)
          runner = @lineage.runner
          return if runner.nil?

          runner.nudged(
            run_public_id: event["run_public_id"],
            task_key: event["task_key"], tool_name: event["tool_name"], role: event["role"]
          )
        rescue *Rho::Env::TaskRun::FATAL => error
          # A process-fatal raise from a tool would end the reactor thread and
          # leave a daemon holding its port and lock answering nothing.
          @log.warn("runner_fatal", error_class: error.class.name,
            detail: "a tool raised a process-fatal error; the daemon is stopping")
          Process.kill("TERM", Process.pid)
        end
    end
  end
end
