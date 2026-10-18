module Runs
  module Parks
    # Park recovery shares one bounded source: expiry and an unclaimed
    # addressee's shutdown both recheck current state under the loop lock.
    class TimeoutSweep
      BUDGET = 500

      FRONTIER_SQL = "#{::Tasks::ParkDeadline::DEADLINE_SQL} <= ?".freeze

      def self.frontier_binds = ::Tasks::ParkDeadline.deadline_binds

      PARKED_TYPES = ::Tasks::PARKED_TYPES

      Candidate = Data.define(:id, :run_id)

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
          Task.where(status: Task::SWEPT_STATUSES)
            .where.not(await_started_at: nil).where(id: (@after_id + 1)..)
            .order(:id).limit(@budget).pluck(:id)
        end

        # Clock arithmetic and the parent predicate apply only after the
        # source ids have been materialized. The locked settle remains final.
        def frontier(now, ids: source_window)
          Task
            .where(id: ids)
            .joins("INNER JOIN runs ON runs.id = tasks.run_id")
            .where(type: PARKED_TYPES, status: Task::SWEPT_STATUSES)
            # A denylist of one word: paused clocks stand still, while
            # `canceling` stays swept so a drain nobody resolves still ends.
            .where.not(runs: { status: "paused" })
            .where.not(await_started_at: nil)
            .where(FRONTIER_SQL, *self.class.frontier_binds, now)
            .order(:id)
            .pluck(:id, :run_id)
            .map { |id, run_id| Candidate.new(id: id, run_id: run_id) }
        end

        def removed_addressees(ids)
          Task.where(id: ids, status: Executor::Convergence::UNCLAIMED_PARKED_STATUSES, claimed_at: nil)
            .where.not(addressed_executor_id: nil)
            .select(:id, :type, :run_id, :status, :claimed_at, :addressed_executor_id)
            .includes(addressed_executor: [:manager, { agent: :steward }])
            .select { |node| addressee_removed?(node) }
            .map { |node| Candidate.new(id: node.id, run_id: node.run_id) }
        end

        def addressee_removed?(node)
          return false unless node.claimed_at.nil? &&
            Executor::Convergence::UNCLAIMED_PARKED_STATUSES.include?(node.status)

          executor = node.addressed_executor
          executor && (executor.revoked? || executor.shutdown_pending?)
        end

        def reconcile(candidate)
          run = nil
          outcome = Run.transaction do
            # This lock orders recovery against claim and pause.
            # Discovery's addressee is advisory: read the current node here.
            run = Run.lock.find_by(id: candidate.run_id)
            next if run.nil? || run.terminal? || run.tombstoned?

            node = run.tasks.find_by(id: candidate.id)
            next if node.nil? || node.terminal?

            if addressee_removed?(node)
              Revoke.call(run: run, node: node)
              EvaluateQuiescence.call(run.reload)
              :revoked
            elsif !run.paused? && Settle.call(node: node, timeout: true).applied?
              :expired
            end
          end
          ScheduleJob.perform_later(candidate.run_id) if outcome == :revoked
          outcome
        rescue StandardError => error
          # The poison-row lesson: one unexpirable park must not abort the
          # batch. It stays on the frontier and the next pass retries it.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "run_park_recovery_failed", run_public_id: run&.public_id })
          nil
        end
    end
  end
end
