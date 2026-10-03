module AgentLoops
  module Tasks
    # Give up on an unresolved failed task: `abandoned` is a :resolved
    # settlement, so dependents proceed and quiescence judges the deliverable
    # — under this verb's own lock, so the loop commits in its final state.
    class Abandon
      Command = Data.define(:agent_loop, :task_key, :acting_user)

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
      end

      def initialize(command)
        @command = command
      end

      def call
        unless @command.agent_loop.writable_by?(@command.acting_user)
          return Result.refused(:not_authorized)
        end

        agent_loop = @command.agent_loop
        return Result.refused(:not_adjudicable) if agent_loop.overridden?

        result, resumed = agent_loop.with_lock { adjudicate(agent_loop) }
        ScheduleJob.perform_later(@command.agent_loop.id) if resumed
        result
      end

      private

        def adjudicate(agent_loop)
          if agent_loop.tombstoned?
            return [Result.refused(:not_found), false]
          end
          unless Retry::ADJUDICABLE_LOOP_STATUSES.include?(agent_loop.status) &&
              !agent_loop.overridden?
            return [Result.refused(:not_adjudicable), false]
          end

          node = agent_loop.agent_loop_nodes.find_by(node_key: @command.task_key)
          return [Result.refused(:task_not_found), false] if node.nil?
          return [Result.refused(:not_abandonable), false] unless node.unresolved_failure?

          # `failure_resolution` is public task shape, so flipping it is a
          # transition the stream must carry.
          Transition.node(node, failure_resolution: "abandoned")
          # The settlement changed pending → resolved: dependents recount NOW,
          # under this same lock, through the one formula.
          Release.settled(node)
          [Result.accepted(node), resume(agent_loop)]
        end

        # The loop's next state is judged HERE, under the lock this
        # adjudication already holds, so what commits is the loop's final
        # state (agent_loops.md, the abandon verb). An abandoned sole
        # deliverable re-holds `deliverable_unresolved` inside this same
        # commit: the converger the status write wakes after commit — and
        # which one worker may run before any scheduler pass — never meets
        # a transient `running` behind the hold-settled turn, where its
        # REOPEN arm would re-settle the variant and a word typed after
        # the abandon would read as pre-hold and wait forever. The
        # quiescence site is level-triggered and built for this lock; with
        # work remaining the loop stays running and the scheduler is woken.
        # Retry keeps the plain release: a re-queued node is work, so its
        # loop legitimately runs and the reopen is the right arm.
        def resume(agent_loop)
          release_hold(agent_loop)
          EvaluateQuiescence.call(agent_loop)
          agent_loop.running?
        end

        # An abandon landing between a node's failure write and the loop's
        # hold finds `running` and writes nothing; the judgement above
        # covers that interleaving the same way.
        def release_hold(agent_loop)
          return unless agent_loop.needs_attention?

          Transition.agent_loop(agent_loop, status: "running", attention_reason: nil)
        end
    end
  end
end
