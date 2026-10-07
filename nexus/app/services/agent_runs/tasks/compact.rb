module AgentRuns
  module Tasks
    # Compact now: the kernel picks no threshold, so a caller who sees a
    # round getting expensive says so. Task-grained — the round carries the
    # history — and queued only, since a started round's request is sealed.
    class Compact
      Command = Data.define(:agent_run, :task_key, :acting_user)

      Result = Data.define(:outcome, :node, :summary_task_key) do
        class << self
          def accepted(node, key) = new(outcome: :accepted, node: node, summary_task_key: key)
          def refused(code) = new(outcome: code, node: nil, summary_task_key: nil)
        end

        def accepted? = outcome == :accepted
      end

      def self.call(command) = new(command).call

      def initialize(command)
        @command = command
      end

      def call
        unless @command.agent_run.writable_by?(@command.acting_user)
          return Result.refused(:not_authorized)
        end

        agent_run = @command.agent_run
        # The seam's veto (`AgentRun#overridden?`): read lock-free early,
        # re-read under the lock in `arm` — the six person's verbs alike.
        return Result.refused(:not_adjudicable) if agent_run.overridden?

        result = agent_run.with_lock { arm(agent_run) }
        ScheduleJob.perform_later(@command.agent_run.id) if result.accepted?
        result
      end

      private

        def arm(agent_run)
          if agent_run.tombstoned?
            return Result.refused(:not_found)
          end
          unless Retry::ADJUDICABLE_LOOP_STATUSES.include?(agent_run.status) && !agent_run.overridden?
            return Result.refused(:not_adjudicable)
          end

          node = agent_run.agent_run_tasks.find_by(node_key: @command.task_key)
          return Result.refused(:task_not_found) if node.nil?
          return Result.refused(:not_compactable) unless node.model_task?
          return Result.refused(:task_not_queued) unless node.status == "queued"

          # Asked before anything mutates: a person who asked is owed which
          # precondition failed, where the automatic caller has one answer.
          refusal = Conversations::Compaction::Arm.refusal_for_round(node)
          return Result.refused(refusal) if refusal

          # A person carries no number, so the arm summarizes: the key it
          # answers is the summarizer's.
          repaired = Conversations::Compaction::Arm.call(
            agent_run: agent_run, node: node,
            trigger: Conversations::Compaction::Trigger.manual(user: @command.acting_user)
          )
          repaired ? Result.accepted(node, repaired.summary_task_key) : Result.refused(:arm_failed)
        end
    end
  end
end
