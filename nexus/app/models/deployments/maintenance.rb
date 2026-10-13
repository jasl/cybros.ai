module Deployments
  # The installation owner closes admission before draining, keeps HTTP available
  # for results, then restarts the app. One Account clock survives that outage;
  # no Run lifecycle or executor claim is replaced by deployment state.
  class Maintenance
    LOCK = "deployments:execution_admission".freeze

    class << self
      def started_at
        Account.uncached { Account.pick(:maintenance_started_at) }
      end

      def active? = started_at.present?

      def effective_now(now)
        started = started_at
        started ? [started, now].min : now
      end

      # Called inside the existing dispatch/claim transaction. Shared holders
      # do not serialize ordinary work; prepare's exclusive side waits for each
      # accepted start to COMMIT before reporting a drain count. No IO spans it.
      def admitting?
        return false if active?

        barrier(shared: true) { !active? } == true
      end

      def prepare
        ApplicationRecord.transaction do
          barrier do
            Account.where(maintenance_started_at: nil)
              .update_all(maintenance_started_at: DatabaseClock.now)
            true
          end || raise("execution maintenance gate is busy")
        end
        status
      end

      def status
        started = started_at
        counts = {
          model_attempts: ModelInvocationAttempt.where(status: "running").count,
          claimed_tools: AgentRunTasks::ToolTask.where(status: "dispatched")
            .where.not(claimed_at: nil).count,
          kernel_tools: AgentRunTasks::ToolTask.where(status: "running").count,
          authorization_exchanges: ModelProviderOAuthTask.dispatching.count,
        }
        drained = counts.values.all?(&:zero?)
        active_work = !drained ||
          AgentRun.where.not(status: AgentRun::TERMINAL_STATUSES + ["paused"]).exists? ||
          ModelInvocation.where.not(status: ModelInvocation::TERMINAL_STATUSES).exists?
        { active: started.present?, started_at: started&.iso8601(6),
          drained: drained, active_work: active_work, **counts }
      end

      # Explicit after successful boot, or after a refused pre-stop drain.
      # Interrupted upgrades retain the gate until the installation owner recovers.
      def resume
        resumed = ApplicationRecord.transaction do
          next false unless active?

          # Pause/Resume and park writers serialize on Run; take every clocked
          # owner, including currently paused ones, before choosing whose debt
          # to pay. Keep these locks through clearing the shared clock.
          runs = AgentRun.where(id: clocked_parks.select(:agent_run_id))
            .or(AgentRun.where(status: "canceling")).order(:id).lock.to_a
          # ProviderStart and expiry serialize on Invocation. Prepared attempts
          # share the outage debt; calls already sent keep their real IO deadline.
          invocations = ModelInvocation.where(id: prepared_attempts.select(:model_invocation_id))
            .order(:id).lock.to_a

          # Acquire after the row ladder: a claimant may already hold one of
          # those rows while acquiring its shared admission fence.
          outcome = barrier do
            started = started_at
            next :unchanged unless started

            now = DatabaseClock.now
            debt_ms = [(now - started).in_milliseconds.round, 0].max
            runs.each do |run|
              next if run.paused?

              clocked_parks.where(agent_run_id: run.id).update_all([
                "await_started_at = await_started_at + (? * interval '1 millisecond')", debt_ms,
              ])
              if run.canceling?
                run.update!(canceling_since: run.canceling_since + debt_ms.fdiv(1_000))
              end
            end
            prepared_attempts.where(model_invocation_id: invocations.map(&:id)).update_all([
              "deadline_at = deadline_at + (? * interval '1 millisecond')", debt_ms,
            ])
            Account.where(maintenance_started_at: started).update_all(maintenance_started_at: nil)
            :resumed
          end
          raise "execution maintenance gate is busy" unless outcome

          outcome == :resumed
        end
        wake if resumed
        status
      end

      private

        def clocked_parks
          AgentRunTask.where(type: AgentRunTasks::PARKED_TYPES, status: AgentRunTask::SWEPT_STATUSES)
            .where.not(await_started_at: nil)
        end

        def prepared_attempts = ModelInvocationAttempt.where(status: "prepared")

        # A cross-row start versus deployment cut has no common aggregate row.
        # The transaction-scoped fence lasts through each existing owner's commit.
        def barrier(shared: false, &block)
          ApplicationRecord.with_advisory_lock(LOCK, shared: shared, transaction: true,
            timeout_seconds: 5, disable_query_cache: true, &block)
        end

        def wake
          ModelProviderOAuthSessions::AdvanceDueJob.perform_later
          ModelProviderOAuthSessions::RefreshDueJob.perform_later
          AgentRuns::ScheduleSweepJob.perform_later
          AgentRuns::ConvergeTerminalStepsJob.perform_later
          ModelInvocations::AdmitQueuedWorkJob.perform_later
          ModelInvocations::RedriveStalledJob.perform_later
        end
    end
  end
end
