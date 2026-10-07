require "digest"
require "json"

module Rho
  class Environments
    # The verb's wait on the call_tool fiber: the live case is create →
    # start → claim → commit → the 1 s poll, ~1-2 s; the verb proceeds
    # with `pending` past it and the fiber runs on to the row's own clock.
    RELAY_GATE_SECONDS = 3
    TOOL_CALL_POLL_SECONDS = 1.0
    # The kernel's error key for a runner that announced no such tool.
    TOOL_NOT_SERVED = "tool_not_served".freeze

    # What a runner elsewhere was told: the tuple's digest, the
    # runner's process life at the time (`booted_at` announced, else
    # `connected_at`, else nil) and how the call_tool ended — `pending`
    # while the fiber runs, `confirmed` with the runner's answer,
    # `unavailable` for a runner that serves no such tool.
    Assertion = Data.define(:digest, :boot, :state, :booted_at, :resolved)
    # The verb's answer for a call_tool: `relayed: confirmed | pending |
    # unavailable`, and what the runner said (nil while pending).
    ToolCallResult = Data.define(:runner, :state, :booted_at, :resolved) do
      def to_h = { runner: runner, state: state, booted_at: booted_at, resolved: resolved }
    end

    # ---- the runner elsewhere ----

    # THE RELAY, keyed by the runner's PROCESS LIFE: the discovery
    # document refreshed first (unless the verb just read it), the key
    # `booted_at` off rho's opaque document, else `connected_at`; relayed
    # when the entry is absent or its digest or boot moved, never when
    # both match. The fiber runs on the reactor and records its answer;
    # the caller waits the gate (`Thread::Queue#pop(timeout:)`) and
    # proceeds with `pending` past it.
    def assert_remote(conversation, runner, binding, plane: nil, document: nil, wait: true, gate: RELAY_GATE_SECONDS)
      plane ||= @member_plane.call(host_public_id: conversation)
      return unavailable(runner) if plane.nil? || runner.nil? || binding.nil?

      document ||= refresh_remote(runner, plane)
      return unavailable(runner) if document.nil?

      boot = boot_of(document)
      digest = digest_of(binding)
      key = [conversation, runner]
      held = @monitor.synchronize { @asserted[key] }
      return answer_of(runner, held) if held && held.digest == digest && held.boot == boot

      assertion = Assertion.new(digest: digest, boot: boot, state: "pending", booted_at: nil, resolved: nil)
      @monitor.synchronize { @asserted = @asserted.merge(key => assertion) }
      answers = Thread::Queue.new
      @spawn.call { answers.push(relay_and_record(plane, key, binding, assertion)) }
      recorded = wait ? answers.pop(timeout: gate) : nil
      recorded ? answer_of(runner, recorded) : ToolCallResult.new(runner: runner, state: "pending", booted_at: nil, resolved: nil)
    end

    # ONCE PER MAINTENANCE CYCLE: every followed conversation bound to a
    # runner elsewhere is re-asserted — one discovery read each — so a
    # runner restarted mid-turn with no prompt pending is told within a
    # cycle. `rows` are the store's binding facts (`host_bindings`).
    def reassert_stale(rows)
      Array(rows).each do |row|
        host = row.fetch(:host)
        next unless host.outlives_turn?

        plane = @member_plane.call(host_public_id: host.public_id)
        next if plane.nil?

        binding_targets(host.public_id, plane:).each do |runner|
          next if runner.nil? || @own_runner.call(runner)

          binding = binding_for(host.public_id, plane:, runner:)
          assert_remote(host.public_id, runner, binding, plane:, wait: false) if binding
        end
      rescue StandardError => error
        @log&.warn("environment.reassert_failed", conversation: row.fetch(:host).public_id, error_class: error.class.name)
      end
    end

    def asserted(conversation, runner) = @monitor.synchronize { @asserted[[conversation, runner]] }

    # ---- the runner slot's receiving table ----

    # A binding a host ELSEWHERE relayed to this slot: process memory,
    # winning over the store; answers whether the root set is on this
    # host (else placement zero there, with the notice on the claim).
    def receive(conversation, binding, runner: @own_runner_public_id.call)
      @monitor.synchronize { @received = @received.merge([conversation, runner] => binding) }
      resolved = resolved?(binding)
      @log&.info("environment.received", conversation: conversation, root: binding.root,
        directories: binding.directories.length, anchor: binding.anchor, resolved: resolved)
      resolved
    end

    def received(conversation, runner: @own_runner_public_id.call) = @monitor.synchronize { @received[[conversation, runner]] }

    private

      # THE WINDOW, SAID: a slot with no member plane holds no
      # store and no walk — a runner-mode daemon restarted mid-conversation
      # forgets its received table by design; a spawned child may be
      # claimed before the host's call_tool lands — so a claim it was never
      # told about lands on placement zero, and the log says so ONCE per
      # conversation (the runner gem memoizes the miss per run; the host's
      # next edge re-relays). No root to name: the reason is the fact.
      def unreceived(conversation)
        notice_once([:unresolved, conversation]) do
          @log&.warn("environment.unresolved", conversation: conversation, reason: "not_received")
        end
        nil
      end

      def digest_of(binding)
        return "none" if binding.nil?

        Digest::SHA256.hexdigest(JSON.generate(value_of(binding)))
      end

      def refresh_remote(runner, plane)
        document = plane.client.executors.show(runner)
        @learn_runner.call(document)
        document
      rescue CybrosAgent::Api::NotFound
        @log&.info("runner.not_addressable", executor: runner, detail: "discovery lists no such runner for this profile")
        nil
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        @log&.warn("runner.discovery_failed", executor: runner, error_class: error.class.name,
          error: CybrosAgent::Redaction.call(error.message))
        nil
      end

      def boot_of(document)
        environment = Hash.try_convert(document.environment) || {}
        environment["booted_at"] || document.connected_at
      end

      def unavailable(runner) = ToolCallResult.new(runner: runner, state: "unavailable", booted_at: nil, resolved: nil)

      def answer_of(runner, assertion)
        ToolCallResult.new(runner: runner, state: assertion.state, booted_at: assertion.booted_at, resolved: assertion.resolved)
      end

      # ON THE FIBER: the request run on the runner's announced park
      # (`timeout_ms: nil`), the rules re-addressed to the seed's origin,
      # the conversation id on the input; the answer recorded — or the
      # entry cleared so the next edge tries again.
      def relay_and_record(plane, key, binding, assertion)
        conversation, runner = key
        detail = begin
          relay_bind(plane, runner, conversation, binding)
        rescue CybrosAgent::Api::InvalidRequest => error
          raise unless error.code == TOOL_NOT_SERVED

          return record(key, assertion, unserved(conversation, runner))
        end
        record(key, assertion, outcome_of(conversation, runner, detail))
      rescue StandardError => error
        @log&.warn("environment.relay_failed", conversation: conversation, runner: runner,
          error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
        record(key, assertion, nil)
      end

      def relay_bind(plane, runner, conversation, binding)
        context = plane.client.workspace(plane.workspace_public_id).runs.start_tool_call(
          runner_executor_public_id: runner, tool: Extensions::Environment::Tools::Bind::NAME,
          input: value_of(binding).merge("conversation_public_id" => conversation), timeout_ms: nil,
          approval_rules: Rho::RunDeclaration.request_rules(guard: @config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(@home)),
          idempotency_key: SecureRandom.uuid
        )
        context.wait_for_tool_result(poll: TOOL_CALL_POLL_SECONDS)
      end

      # The assertion the terminal task earns: `confirmed` with the
      # runner's answer, `unavailable` for a runner without the tool
      # (said once per boot), nil for every other terminal.
      def outcome_of(conversation, runner, detail)
        task = detail.task
        if task.status == "completed" && !task.result&.dig("is_error")
          structure = Hash.try_convert(detail.structured_content) || {}
          @log&.info("environment.relayed", conversation: conversation, runner: runner,
            booted_at: structure["booted_at"], resolved: structure["resolved"])
          return ["confirmed", structure["booted_at"], structure["resolved"]]
        end
        if task.error&.dig("key") == TOOL_NOT_SERVED
          return unserved(conversation, runner)
        end
        if task.status == "completed"
          @log&.warn("environment.relay_refused", conversation: conversation, runner: runner, detail: detail.output.to_s)
          return ["unavailable", nil, false]
        end

        @log&.warn("environment.relay_failed", conversation: conversation, runner: runner, status: task.status,
          key: task.error&.dig("key"))
        nil
      end

      def unserved(conversation, runner)
        @log&.warn("environment.unrelayed", conversation: conversation, runner: runner,
          detail: "the runner serves no environment_bind; the lead names its announced root")
        ["unavailable", nil, nil]
      end

      def record(key, assertion, outcome)
        if outcome.nil?
          @monitor.synchronize { @asserted = @asserted.except(key) }
          return Assertion.new(digest: assertion.digest, boot: assertion.boot, state: "unavailable", booted_at: nil, resolved: nil)
        end

        state, booted_at, resolved = outcome
        recorded = assertion.with(state: state, booted_at: booted_at, resolved: resolved)
        @monitor.synchronize { @asserted = @asserted.merge(key => recorded) }
        recorded
      end
  end
end
