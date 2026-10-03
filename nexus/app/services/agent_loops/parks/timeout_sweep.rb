module AgentLoops
  module Parks
    # Park recovery shares one bounded source: expiry and an unclaimed
    # addressee's shutdown both recheck current state under the loop lock.
    class TimeoutSweep
      BUDGET = 500

      # The SQL twin of AgentLoopNodes::Parked#effective_timeout_ms, three
      # arms: a HELD row on the approver's clock first (the ask's MAX_HOLD,
      # whatever the tool's run clock says), then the tool arm's three
      # sources, then the await's clamp; the mirror test pins them equal.
      FRONTIER_SQL = <<~SQL.squish.freeze
        agent_loop_nodes.await_started_at + (
          CASE
            WHEN agent_loop_nodes.status = 'needs_approval'
              THEN CAST(? AS bigint)
            WHEN agent_loop_nodes.type IN ('AgentLoopNodes::ToolTask', 'AgentLoopNodes::ScriptTask')
              THEN COALESCE(
                agent_loop_nodes.timeout_ms,
                (agent_loop_nodes.effect_profile->>'timeout_ms')::bigint,
                CAST(? AS bigint)
              )
            ELSE LEAST(
              COALESCE(agent_loop_nodes.await_timeout_ms, CAST(? AS bigint)),
              CAST(? AS bigint)
            )
          END * interval '1 millisecond'
        ) <= ?
      SQL

      # The binds of FRONTIER_SQL in order, less `now`: the held arm's hold,
      # the tool default, the await default, the await clamp. One list, so
      # a probe of the shipped SQL binds what the sweep binds.
      def self.frontier_binds
        [
          AgentLoopNodes::AwaitTask::MAX_HOLD_MS,
          AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS,
          AgentLoopNodes::AwaitTask::DEFAULT_TIMEOUT_MS,
          AgentLoopNodes::AwaitTask::MAX_HOLD_MS,
        ]
      end

      PARKED_TYPES = AgentLoopNodes::PARKED_TYPES

      Candidate = Data.define(:id, :agent_loop_id)

      def self.call(...) = new(...).call

      def initialize(after_id: 0, budget: BUDGET)
        @after_id = after_id.to_i
        @budget = budget
      end

      def call
        now = DatabaseClock.now
        ids = source_window
        candidates = (frontier(now, ids: ids) + removed_addressees(ids)).uniq(&:id)
        outcomes = candidates.map { |candidate| reconcile(candidate) }

        # `expired` counts the expiries the settle APPLIED, whichever word
        # they settled to — `timed_out` or `uncertain` is the rule's, not the sweep's.
        Sweeps::Pass.new(
          counts: { expired: outcomes.count(:expired), revoked: outcomes.count(:revoked), scanned: ids.length },
          cursor: ids.last || @after_id,
          more: @budget.positive? && ids.length == @budget
        )
      end

      private

        # Retained parks consume source budget too: a paused or not-yet-due
        # page must not hide later work, nor scan beyond the indexed window.
        def source_window
          AgentLoopNode.where(status: AgentLoopNode::SWEPT_STATUSES)
            .where.not(await_started_at: nil).where(id: (@after_id + 1)..)
            .order(:id).limit(@budget).pluck(:id)
        end

        # Clock arithmetic and the parent predicate apply only after the
        # source ids have been materialized. The locked settle remains final.
        def frontier(now, ids: source_window)
          AgentLoopNode
            .where(id: ids)
            .joins("INNER JOIN agent_loops ON agent_loops.id = agent_loop_nodes.agent_loop_id")
            .where(type: PARKED_TYPES, status: AgentLoopNode::SWEPT_STATUSES)
            # A denylist of one word: paused clocks stand still, while
            # `canceling` stays swept so a drain nobody resolves still ends.
            .where.not(agent_loops: { status: "paused" })
            .where.not(await_started_at: nil)
            .where(FRONTIER_SQL, *self.class.frontier_binds, now)
            .order(:id)
            .pluck(:id, :agent_loop_id)
            .map { |id, agent_loop_id| Candidate.new(id: id, agent_loop_id: agent_loop_id) }
        end

        def removed_addressees(ids)
          AgentLoopNode.where(id: ids, status: TaskExecutor::Convergence::UNCLAIMED_PARKED_STATUSES, claimed_at: nil)
            .where.not(addressed_executor_id: nil)
            .select(:id, :type, :agent_loop_id, :status, :claimed_at, :addressed_executor_id)
            .includes(addressed_executor: [:manager, { agent_profile: :steward }])
            .select { |node| addressee_removed?(node) }
            .map { |node| Candidate.new(id: node.id, agent_loop_id: node.agent_loop_id) }
        end

        def addressee_removed?(node)
          return false unless node.claimed_at.nil? &&
            TaskExecutor::Convergence::UNCLAIMED_PARKED_STATUSES.include?(node.status)

          executor = node.addressed_executor
          executor && (executor.revoked? || executor.shutdown_pending?)
        end

        def reconcile(candidate)
          agent_loop = nil
          outcome = AgentLoop.transaction do
            # This lock orders recovery against claim, handoff and pause.
            # Discovery's addressee is advisory: read the current node here.
            agent_loop = AgentLoop.lock.find_by(id: candidate.agent_loop_id)
            next if agent_loop.nil? || agent_loop.terminal? || agent_loop.tombstoned?

            node = agent_loop.agent_loop_nodes.find_by(id: candidate.id)
            next if node.nil? || node.terminal?

            if addressee_removed?(node)
              Revoke.call(agent_loop: agent_loop, node: node)
              EvaluateQuiescence.call(agent_loop.reload)
              :revoked
            elsif !agent_loop.paused? && Settle.call(node: node, timeout: true).applied?
              :expired
            end
          end
          ScheduleJob.perform_later(candidate.agent_loop_id) if outcome == :revoked
          outcome
        rescue StandardError => error
          # The poison-row lesson: one unexpirable park must not abort the
          # batch. It stays on the frontier and the next pass retries it.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "agent_loop_park_recovery_failed", agent_loop_public_id: agent_loop&.public_id })
          nil
        end
    end
  end
end
