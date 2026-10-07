module AgentRuns
  # The two-phase stop: phase one cancels under the loop lock, phase two is the
  # converger and the drain. Stopping spend is never refused.
  class Stop
    Command = Data.define(:agent_run, :acting_user, :force) do
      def self.forced(agent_run:, acting_user:)
        new(agent_run: agent_run, acting_user: acting_user, force: true)
      end
    end

    Result = Data.define(:outcome) do
      class << self
        def accepted = new(outcome: :accepted)
        def refused(code) = new(outcome: code)
      end

      def accepted? = outcome == :accepted
    end

    class << self
      def call(command)
        new(command).call
      end

      # THE KERNEL'S OWN ACT: the forced stop with no standing gate, for a
      # verb that passed standing on the loop's conversation already (a
      # side's DELETE, the parent's cascade). The same locked path, the
      # same follow-up jobs.
      def stop_now(agent_run)
        new(Command.forced(agent_run: agent_run, acting_user: nil)).stop_now
      end

      # The caller holds the loop lock and owns its next wake. A scheduler
      # already running this drain must not enqueue itself before quiescence.
      def cancel_locked(agent_run, force: true)
        return Result.refused(:not_found) if agent_run.tombstoned?
        already_stopped = agent_run.stopped?
        if (force || agent_run.terminal?) && !already_stopped
          agent_run.update!(stopped_at: Time.current)
        end
        if agent_run.terminal?
          return already_stopped ? Result.refused(:already_terminal) : Result.accepted
        end
        if agent_run.canceling?
          # A graceful stop escalates; stopping again gracefully is idle.
          force_in_flight(agent_run) if force
          return Result.accepted
        end

        if agent_run.pending?
          cancel_unstarted_nodes(agent_run)
          Transition.agent_run(agent_run, status: "canceled", completed_at: Time.current)
          return Result.accepted
        end

        terminate(agent_run, force: force)
        Result.accepted
      end

      # A variant replacement must cut the old owner before building the new
      # graph, without taking its invocation/body suffix locks. Recovery owns
      # the drain; both hints are after-commit and rollback with a refused edit.
      def mark_now(agent_run)
        agent_run.with_lock { agent_run.update!(stopped_at: Time.current) unless agent_run.stopped? }
        ScheduleJob.perform_later(agent_run.id)
        Spawn::RelayJob.perform_later
        Spawn::RelayJob.perform_later(nil, { "source_run_public_id" => agent_run.public_id })
      end

      # Shared with the scheduler's authority recheck. Lock order is the
      # order of this method: in-flight steps terminalize first, because
      # narration takes the event cursor, which ranks below model_invocations.
      def terminate(agent_run, failure_reason: nil, step_reason: "creator_requested",
                     force: true)
        cancel_running_steps(agent_run, step_reason) if force
        # Stop-from-paused repays the pause debt before the status flips, or
        # the sweep would expire its parks against frozen deadlines.
        agent_run.unfreeze
        Transition.agent_run(
          agent_run,
          status: "canceling",
          stopped_at: force ? (agent_run.stopped_at || Time.current) : agent_run.stopped_at,
          canceling_since: Time.current,
          paused_at: nil,
          failure_reason: failure_reason,
          attention_reason: nil
        )
        cancel_unstarted_nodes(agent_run)
        cancel_forced_parks(agent_run) if force
      end

      # The escalation arm: a loop already draining gracefully stops NOW.
      def force_in_flight(agent_run)
        cancel_running_steps(agent_run, "creator_requested")
        cancel_forced_parks(agent_run)
      end

      # Everything that has spent nothing — a queued row AND a row resting
      # at the approval stage: the drain never waits on either, so a stop
      # must take both or leave an approval nobody will answer. The reason
      # rides the row (change 7), as it does on the parks below.
      def cancel_unstarted_nodes(agent_run)
        Transition.nodes(
          agent_run.agent_run_tasks.where(status: AgentRunTask::PRE_DISPATCH_STATUSES),
          status: "canceled", completed_at: Time.current, error_key: "run_canceled"
        )
      end

      # Work with no invocation cancels directly. A delegation's target is
      # stopped by the relay after this transaction, in target lock order.
      def cancel_forced_parks(agent_run)
        cancel_parked(agent_run, "AgentRunTasks::AwaitTask")
        cancel_parked(agent_run, "AgentRunTasks::ToolTask")
        cancel_parked(agent_run, "AgentRunTasks::DelegationTask")
      end

      # A claimed row's holder is told on its own stream, so it kills
      # what it spawned; an unclaimed one simply leaves the inbox.
      def cancel_parked(agent_run, type)
        agent_run.agent_run_tasks
          .where(status: AgentRunTask::STARTED_STATUSES, type: type)
          .find_each do |node|
            Transition.node(node, status: "canceled", completed_at: Time.current,
              error_key: "run_canceled")
            Executors::Nudge.work_canceled(node)
          end
      end

      # Ascending id: the same within-table order `CancelLosers` takes, so
      # the two can never hold each other's next row (the ladder ranks
      # tables; a multi-row locker owes its own direction).
      def cancel_running_steps(agent_run, step_reason)
        ids = agent_run.agent_run_tasks
          .where(status: "running")
          .where.not(selected_model_invocation_id: nil)
          .pluck(:selected_model_invocation_id).compact.uniq.sort
        ModelInvocation.where(id: ids).order(:id).lock.each do |invocation|
          invocation.terminalize(status: "canceled", reason_key: step_reason)
          # The converger applies the terminal back to the node.
        end
      end
    end

    def initialize(command)
      @command = command
    end

    def call
      unless @command.agent_run.writable_by?(@command.acting_user)
        return Result.refused(:not_authorized)
      end

      stop_now
    end

    def stop_now
      result = @command.agent_run.with_lock { self.class.cancel_locked(@command.agent_run, force: @command.force) }
      if result.accepted?
        ConvergeTerminalStepsJob.perform_later
        ScheduleJob.perform_later(@command.agent_run.id)
        Spawn::RelayJob.perform_later
        Spawn::RelayJob.perform_later(nil, { "source_run_public_id" => @command.agent_run.public_id })
      end
      result
    end
  end
end
