module Rho
  class Daemon
    # THE EXECUTOR PLANE'S TWO VERBS, out of `HostFollowers` because runner mode constructs no
    # `HostFollowers`: what an ADDRESS announces it serves, and the nudge stream on that address's
    # inbox channel. One implementation for every mode and both addresses — the runner's
    # (`:runner`, the environment tools with the root's environment document) and the
    # agent's (`:agent_runner`, the agent's own tools, no environment). The member-plane
    # verbs stay in `HostFollowers`.
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
      # The address each slot serves, as the log names it.
      ADDRESSES = { runner: "runner", agent_runner: "agent" }.freeze
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

      # WHAT AN ADDRESS SERVES, written on the same edge as
      # the declaration but on the executor plane and BEFORE the runner
      # follows: the kernel addresses a call to an address only if it
      # announced the name, so a runner that followed first would meet
      # `tool_not_served` on the turn's first call. `registry` is the
      # address's projection; `environment` the ROOT's document
      # for the runner address — nil for the agent's, so the SDK omits the
      # key and the kernel stores none — and `documents` what the address's
      # own providers announce:
      # the runner's carries the root's skills and its stdio MCP servers'
      # prompts, the agent's only what its extensions announce, no
      # environment (an http MCP server's prompts). A refusal costs the
      # announcement, never the runner — the snapshot's `announced` says so.
      # `extras`: the agent slot's entries
      # beyond the registry's — every anchor's editor servers — announced
      # with the registry's as one list, a name once.
      def announce_tools(credential, registry:, environment:, documents: nil, slot: :runner, extras: [])
        address = ADDRESSES.fetch(slot)
        tools = RunDeclaration.announcement(registry: registry, extras: extras)
        @wire.executor_client(credential).announce(tools: tools, environment: environment, documents: documents)
        @announced[address] = tools.length
        @log.info("executor.announced", tools: tools.length, address: address, documents: documents&.length)
      rescue CybrosAgent::Error => error
        @announced[address] = nil
        @log.warn("executor.announcement_failed", address: address, error_class: error.class.name,
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
      def nudge_stream(about, slot = :runner)
        client = @lineage.executor_realtime_for(about, slot: slot)
        return if client.nil? || client.connected?

        while listening?(client, slot)
          begin
            consume_nudges(client, slot)
            break
          rescue CybrosAgent::Realtime::ConnectionLostError, CybrosAgent::TransportError => error
            log_stream_end(slot, error)
          end
          sleep(RECONNECT_SECONDS) if listening?(client, slot)
        end
      rescue StandardError => error
        log_stream_end(slot, error)
      end

      private

        def listening?(client, slot)
          !@lineage.stopping? && @lineage.executor_realtime(slot).equal?(client)
        end

        def log_stream_end(slot, error)
          @log.warn("executor_nudge_stream_ended", address: ADDRESSES.fetch(slot), error_class: error.class.name,
            error: CybrosAgent::Redaction.call(error.message))
        end

        def consume_nudges(client, slot)
          client.connect unless client.connected?
          subscription = client.subscribe(channel: EXECUTOR_INBOX_CHANNEL, params: {})
          subscription.each do |message|
            break unless listening?(client, slot)

            event = Hash.try_convert(Hash.try_convert(message)&.fetch("event", nil))
            next unless event

            case event["type"]
            when WORK_AVAILABLE
              # One fiber per nudge: `nudged` waits for the tool's answer, and
              # running it here starved the next nudge until the current tool
              # finished. The pool declines when full, so this cannot pile up.
              # An `ask` kind is the agent application's row, and
              # an `approval` kind a call held for a person —
              # neither the runner's: each is noted — the daemon's ask or
              # approval notice — and never dispatched; the inbox is the
              # level-triggered truth `rho status` and `GET /asks` read, and
              # the follower's ASKING line stays the person's live signal. A
              # kind this version does not know is left to the sweep, which
              # carries it.
              case event["kind"]
              when TOOL_CALL_KIND then @context.spawn { dispatch_nudge(event, slot) }
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
              @lineage.runners.each do |runner|
                runner.cancel(run_public_id: event["run_public_id"], task_key: event["task_key"])
              end
            else
              # A frame this version does not know: the row is the fact and
              # the sweep will read it.
              nil
            end
          end
          @log.info("executor_nudge_stream_ended", address: ADDRESSES.fetch(slot), reason: "closed")
        ensure
          subscription&.unsubscribe
        end

        def root_environment = Rho::Runner::Environment.local(root: @context.tool_env.root)

        # The runner of the moment, not the stream's: `rho env` rebuilds it,
        # and a captured one handed every nudge to a stopped runner (the
        # signature is `nudged: 0` beside a rising `swept`).
        def dispatch_nudge(event, slot)
          runner = @lineage.runner(slot)
          return if runner.nil?

          runner.nudged(
            run_public_id: event["run_public_id"],
            task_key: event["task_key"], tool_name: event["tool_name"]
          )
        rescue *Rho::Runner::TaskRun::FATAL => error
          # A process-fatal raise from a tool would end the reactor thread and
          # leave a daemon holding its port and lock answering nothing.
          @log.warn("runner_fatal", error_class: error.class.name,
            detail: "a tool raised a process-fatal error; the daemon is stopping")
          Process.kill("TERM", Process.pid)
        end
    end
  end
end
