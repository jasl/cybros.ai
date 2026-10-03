module AgentLoops
  # The drain's recovering sweep and hard end: quiescence re-evaluated
  # level-triggered over every canceling loop, and a drain older than the
  # longest park escalates to the forced-stop arm — the bound on what a hang
  # can cost. The job is its shell.
  class DrainSweep
    HARD_LIMIT = AgentLoopNodes::AwaitTask::MAX_HOLD

    def self.call(batch: 200, after_id: 0) = new(batch, after_id).call

    def initialize(batch, after_id)
      @batch = batch
      @after_id = after_id
    end

    def call
      ids = AgentLoop.where(status: "canceling").where(id: (@after_id + 1)..)
        .order(:id).limit(@batch).pluck(:id)
      escalated = ids.count { |agent_loop_id| drain(agent_loop_id) }

      # Waiting and failed rows keep their place in this pass's budget. The
      # next recurring wake revisits them after this chain reaches its end.
      Sweeps::Pass.new(counts: { scanned: ids.length, escalated: escalated },
        cursor: ids.last || @after_id, more: @batch.positive? && ids.length == @batch)
    end

    private

      # The poison-row lesson (the sibling walkers' own comment): one
      # undrainable loop must not abort the batch — every other canceling
      # loop still gets its re-evaluation and its hard limit.
      def drain(agent_loop_id)
        escalated = false
        AgentLoop.transaction do
          # The loop row orders the drain against a racing settle: the
          # forced stop and the quiescence read must see one frontier, and
          # a CAS cannot express "every node of this loop".
          agent_loop = AgentLoop.lock.find_by(id: agent_loop_id)
          next if agent_loop.nil? || !agent_loop.canceling?

          if overdue?(agent_loop)
            Stop.force_in_flight(agent_loop)
            escalated = true
          end
          EvaluateQuiescence.call(agent_loop)
        end
        escalated
      rescue StandardError => error
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "agent_loop_drain_sweep_failed", agent_loop_id: agent_loop_id })
        false
      end

      def overdue?(agent_loop)
        agent_loop.canceling_since <= HARD_LIMIT.ago
      end
  end
end
