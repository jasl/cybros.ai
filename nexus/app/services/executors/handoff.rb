module Executors
  # THE HANDOFF: the explicit switch of a host's runner binding,
  # and the one place unclaimed work is re-addressed. In order — the caller rule,
  # the target rule, the guarded write, then the
  # re-address pass over the host's live loops.
  #
  # The write order, verbatim: host row lock → `runner_executor_id` →
  # commit → then, per live loop of the host, loop lock → the re-address
  # pass. Two transactions, level-triggered by the binding: if the process
  # dies between them, the next `start_node` of any NEW row reads the new
  # binding (Executors::Address), and the old unclaimed rows park to their
  # deadline — degraded, never corrupt. No lock is held across hosts and
  # loops; `task_executors` is read lock-free throughout (it ranks ABOVE the
  # host rungs on the ladder — a lock inside the host transaction would
  # invert it).
  #
  # The pass re-runs THE ONE addressing site (`Executors::Address.tool`)
  # against the new binding and takes its answer as a start takes it: a
  # Decision re-addresses the row with its park clock re-armed, narrated
  # `task_readdressed` and nudged; a Refusal fails the row through FailNode
  # (`tool_not_served`, `on_failure` honoured). A claimed row is untouched —
  # `claimed_at IS NULL` is re-read on the LOCKED row, and the claim takes
  # the same lock, so a claim that lands between the host commit and the
  # loop lock simply keeps its row.
  class Handoff
    Command = Data.define(:host, :executor_public_id, :acting_user)

    Readdressed = Data.define(:agent_loop_public_id, :task_key, :outcome)

    # The accepted answer's value: the host as bound, and the rows the pass
    # re-addressed — none when the same id was already bound (idempotent by
    # value: no item written, no pass run).
    Binding = Data.define(:host, :readdressed)

    # The reasons `eligible_for?` refuses, in its own order — the detail a
    # person reads on `runner_not_eligible`.
    NOT_ELIGIBLE_REASONS = {
      revoked: "revoked",
      no_credential: "no ready credential",
      shutdown_pending: "shutdown pending",
      out_of_scope: "not in scope for this host's principal",
    }.freeze

    def self.call(command) = new(command).call

    def initialize(command)
      @command = command
    end

    def call
      host = @command.host
      return Outcome.refused(:not_authorized) unless caller_may_bind?(host)

      executor = find_target(host)
      return Outcome.refused(:runner_not_found) if executor.nil?

      reason = ineligibility(executor, host.answering_user)
      return Outcome.refused(:runner_not_eligible, detail: NOT_ELIGIBLE_REASONS.fetch(reason)) if reason

      case host.bind_runner(executor, by: @command.acting_user)
      when :runner_unchanged then Outcome.accepted(Binding.new(host: host, readdressed: []))
      else Outcome.accepted(Binding.new(host: host, readdressed: readdress_live_loops(host)))
      end
    end

    private

      # The caller rule: the HOST's declaring profile — its ANSWERER, when
      # an agent — on its own bearer, or a Human with write standing ON THE
      # HOST (a Human the conversation lists at `read` has none, whatever
      # the workspace says; the answerer is full by derivation). Any other
      # agent has no standing — this is the one verb that moves where a
      # model's effects land, and an agent that does not run the host has
      # no say in it. A transport credential never reaches the route (the
      # member plane).
      def caller_may_bind?(host)
        acting_user = @command.acting_user
        return false unless host.writable_by?(acting_user)

        !acting_user.agent? || host.declaring_profile == acting_user
      end

      # The target rule, read lock-free: a runner-kind row of the host's
      # account. A tools provider is a pool member, never a binding; an
      # agent address binds nothing — both conceal as absence.
      def find_target(host)
        executor = TaskExecutor.find_by(account_id: host.account_id, public_id: @command.executor_public_id)
        executor if executor&.runner?
      end

      # `eligible_for?`'s own conjuncts, named — the principal is the HOST's
      # answerer (a conversation's answering profile, a standalone loop's
      # creator), never the caller.
      def ineligibility(executor, principal)
        return :revoked unless executor.active?
        return :no_credential unless TaskExecutor.credential_readiness_for([executor]).fetch(executor.id) == :ready
        return :shutdown_pending if executor.shutdown_pending?

        :out_of_scope unless executor.eligible_for?(principal)
      end

      # After the host transaction committed: one transaction PER LIVE LOOP,
      # never across them. A failed row's release is drained by
      # `ScheduleReady` in ITS own lock afterwards — it starts queued rows
      # only, so a re-addressed `dispatched` row is never nudged twice.
      def readdress_live_loops(host)
        live_loop_ids(host).flat_map do |agent_loop_id|
          readdressed = readdress_loop(agent_loop_id)
          if readdressed.any? { |entry| entry.outcome == :failed }
            AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop_id)
          end
          readdressed
        end
      end

      def live_loop_ids(host)
        host.hosted_agent_loops.where.not(status: AgentLoop::TERMINAL_STATUSES).order(:id).pluck(:id)
      end

      # Loop lock → the locked node rows → the transition and its narration
      # (the cursor) → commit. The nodes come through the locked loop's
      # association, so `Address.tool` reads the committed binding off the
      # locked instance.
      def readdress_loop(agent_loop_id)
        AgentLoop.transaction do
          agent_loop = AgentLoop.lock.find(agent_loop_id)
          rows = agent_loop.agent_loop_nodes.lock
            .where(type: AgentLoopNodes::ToolTask.sti_name, status: "dispatched",
              addressed_role: "runner", claimed_at: nil)
            .order(:id).to_a
          worklist = []
          rows.map { |node| readdress(agent_loop, node, worklist) }
        end
      end

      def readdress(agent_loop, node, worklist)
        decision = Executors::Address.tool(node)
        if decision.refused?
          AgentLoops::FailNode.call(agent_loop: agent_loop, node: node, error_key: decision.error_key,
            error_detail: decision.detail, worklist: worklist)
          return Readdressed.new(agent_loop_public_id: agent_loop.public_id, task_key: node.node_key, outcome: :failed)
        end

        # The park clock is re-armed at the loop's VIRTUAL clock: on a paused
        # loop the clocks stand still and `unfreeze` shifts this row with the
        # others — a wall-clock re-arm would hand it the pause a second time.
        # `task_readdressed` is the ONE item of this write: the status did
        # not move, so no `task_status` rides beside it.
        AgentLoops::Transition.node(node, narrate: false,
          addressed_executor_id: decision.executor&.id, addressed_role: decision.role,
          effect_profile: decision.effect_profile, await_started_at: agent_loop.effective_now)
        AgentLoop::Narration.record(agent_loop, [{
          type: "task_readdressed",
          payload: {
            "task_key" => node.node_key,
            "role" => decision.role,
            "executor_public_id" => decision.executor&.public_id,
            "deadline_at" => node.deadline_at.iso8601,
          }.compact,
        }])
        Executors::Nudge.work_available(node)
        Readdressed.new(agent_loop_public_id: agent_loop.public_id, task_key: node.node_key, outcome: :readdressed)
      end
  end
end
