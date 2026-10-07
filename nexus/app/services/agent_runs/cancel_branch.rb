module AgentRuns
  # THE PERSON-SIDE BRANCH CANCEL: the descendant closure of the named node
  # along outgoing edges — the mirror of CancelLosers' ancestor walk —
  # stopping at every round-marked node and every barrier without cancelling
  # them. The target is the CALL key the model saw (`r3t1`, whose branch
  # hangs off it) or any branch node; a round-marked key or a mainline fan
  # member refuses `not_a_branch` (the person's verb for the mainline is
  # `stop`). Every cancelled row settles `canceled` with a RESOLUTION, so a
  # blocking consumer runs and reads `status="canceled"`, and a detached tip
  # is delivered — by the wake in flight, by mail after the reply is final.
  class CancelBranch
    REASON = "task_canceled".freeze
    RESOLUTION = "canceled".freeze

    Command = Data.define(:agent_run, :task_key, :acting_user)

    Result = Data.define(:outcome, :node) do
      class << self
        def accepted(node) = new(outcome: :accepted, node: node)
        def refused(code) = new(outcome: code, node: nil)
      end

      def accepted? = outcome == :accepted
    end

    class << self
      def call(command)
        new(command).call
      end

      # Task-scoped commands have already proved ownership under the loop lock.
      def cancel_locked(agent_run:, targets:)
        new(Command.new(agent_run: agent_run, task_key: nil, acting_user: nil)).cancel_targets(targets)
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      agent_run = @command.agent_run
      unless agent_run.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      result = agent_run.with_lock { adjudicate(agent_run) }
      if result.accepted?
        ConvergeTerminalStepsJob.perform_later
        ScheduleJob.perform_later(agent_run.id)
      end
      result
    end

    def cancel_targets(targets)
      live = targets.reject(&:terminal?)
      running, parked = live.partition { |row| running_step_id(row) }
      terminalize_after_commit(running.map { |row| running_step_id(row) })
      parked.each do |row|
        Transition.node(row, status: "canceled", completed_at: Time.current,
          error_key: REASON, failure_resolution: RESOLUTION)
        Executors::Nudge.work_canceled(row)
        Release.settled(row)
      end
      live
    end

    private

      def adjudicate(agent_run)
        return Result.refused(:not_found) if agent_run.tombstoned?
        unless Tasks::Retry::ADJUDICABLE_LOOP_STATUSES.include?(agent_run.status)
          return Result.refused(:not_adjudicable)
        end

        node = agent_run.agent_run_tasks.find_by(node_key: @command.task_key)
        return Result.refused(:task_not_found) if node.nil?

        targets = BranchClosure.members(node)
        return Result.refused(:not_a_branch) if targets.empty?

        live = targets.reject(&:terminal?)
        return Result.refused(:already_terminal) if live.empty?

        # The in-flight half settles after commit (the converger applies the
        # terminal); the queued and parked half settles now, and each
        # settlement recounts its consumers through the one formula.
        cancel_targets(live)
        Result.accepted(node)
      end

      def running_step_id(row)
        row.selected_model_invocation_id if row.holds_invocation?
      end

      # Ascending id, the order every multi-invocation locker in this plane
      # pins; the node settles when the converger applies the terminal.
      def terminalize_after_commit(invocation_ids)
        ids = invocation_ids.compact.uniq.sort
        return if ids.empty?

        ApplicationRecord.current_transaction.after_commit do
          ApplicationRecord.transaction do
            ModelInvocation.where(id: ids).order(:id).lock.each do |invocation|
              invocation.terminalize(status: "canceled", reason_key: REASON)
            end
          end
        end
      end
  end
end
