module AgentLoops
  module Tasks
    # Compact now: the kernel picks no threshold, so a caller who sees a
    # round getting expensive says so. Task-grained — the round carries the
    # history — and queued only, since a started round's request is sealed.
    class Compact
      Command = Data.define(:agent_loop, :task_key, :acting_user)

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
        unless @command.agent_loop.writable_by?(@command.acting_user)
          return Result.refused(:not_authorized)
        end

        agent_loop = @command.agent_loop
        # The seam's veto (`AgentLoop#overridden?`): read lock-free early,
        # re-read under the lock in `arm` — the six person's verbs alike.
        return Result.refused(:not_adjudicable) if agent_loop.overridden?

        result = agent_loop.with_lock { arm(agent_loop) }
        ScheduleJob.perform_later(@command.agent_loop.id) if result.accepted?
        result
      end

      private

        def arm(agent_loop)
          if agent_loop.tombstoned?
            return Result.refused(:not_found)
          end
          unless Retry::ADJUDICABLE_LOOP_STATUSES.include?(agent_loop.status) && !agent_loop.overridden?
            return Result.refused(:not_adjudicable)
          end

          node = agent_loop.agent_loop_nodes.find_by(node_key: @command.task_key)
          return Result.refused(:task_not_found) if node.nil?
          return Result.refused(:not_compactable) unless node.round?
          return Result.refused(:task_not_queued) unless node.status == "queued"

          # Asked before anything mutates: a person who asked is owed which
          # precondition failed, where the automatic caller has one answer.
          refusal = Conversations::Compaction::Arm.refusal_for_round(node)
          return Result.refused(refusal) if refusal

          # A person carries no number, so the arm summarizes: the key it
          # answers is the summarizer's.
          repaired = Conversations::Compaction::Arm.call(
            agent_loop: agent_loop, node: node,
            trigger: Conversations::Compaction::Trigger.manual(user: @command.acting_user)
          )
          repaired ? Result.accepted(node, repaired.summary_task_key) : Result.refused(:arm_failed)
        end
    end
  end
end
