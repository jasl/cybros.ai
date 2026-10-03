module AgentLoops
  module Tasks
    # THE APPROVER'S GRANT: a person — or the agent application acting for
    # one — releases a row resting at `needs_approval`. Retry's shape: the
    # workspace gate, the seam's veto, the loop lock, the adjudicable
    # statuses (a `needs_attention` loop approves without releasing its
    # hold: the hold is its failure's). The release re-runs THE ONE
    # addressing site, so a runner bound or handed off during the park is
    # honoured — and RE-PARKS when the effect profile the approver read is
    # not the one the call would run under now.
    class Approve
      ADJUDICABLE_LOOP_STATUSES = Retry::ADJUDICABLE_LOOP_STATUSES

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

        # THE ONE GRANT SITE: the stage under a grant and the verb share this
        # body — the dispatch or the kernel run, the run clock, the
        # addressing decision, the nudge, and the fact: `origin` and the
        # time; `approved_by` is a principal's grant alone (`human|agent`). A
        # row resting held whose fresh decision carries a DIFFERENT effect
        # profile is not released: it rests again with the new profile and
        # its clock re-armed at the loop's virtual clock (the handoff's rule)
        # — the address stays the agent application — narrated once, and
        # `:reparked` is the answer. A row RESTING held carries the profile
        # its approver read; the stage's own crossing carries none yet, so
        # under a grant at the stage the comparison is vacuous. No worklist:
        # a release starts a row and settles nothing.
        def release(agent_loop, node, decision:, origin:, approved_by: nil)
          if node.held? && node.effect_profile.present? && decision.effect_profile != node.effect_profile
            Transition.node(node, effect_profile: decision.effect_profile,
              await_started_at: agent_loop.effective_now)
            return :reparked
          end

          now = Time.current
          # The run clock is armed at the loop's VIRTUAL clock (the handoff's
          # rule): a paused loop's row would otherwise be handed the pause
          # twice at resume; on a running loop the two clocks are one.
          Transition.node(node,
            status: decision.status, started_at: now, await_started_at: agent_loop.effective_now(now),
            addressed_executor_id: decision.executor&.id, addressed_role: decision.role,
            effect_profile: decision.effect_profile,
            approval_origin: origin, approved_by_user_id: approved_by&.id, approval_decided_at: now)
          if decision.status == "running"
            Dispatch.after_commit(node)
          else
            Executors::Nudge.work_available(node)
          end
          :released
        end

        # The fact's origin is the approver's KIND, never "person": a
        # transcript tells a delegate's grant from the person's.
        def origin_of(acting_user) = acting_user.agent? ? "agent" : "human"
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
        # The pass re-evaluates quiescence and clears `approval_required`.
        ScheduleJob.perform_later(agent_loop.id) if resumed
        result
      end

      private

        def adjudicate(agent_loop)
          return [Result.refused(:not_found), false] if agent_loop.tombstoned?
          unless ADJUDICABLE_LOOP_STATUSES.include?(agent_loop.status) && !agent_loop.overridden?
            return [Result.refused(:not_adjudicable), false]
          end

          node = agent_loop.agent_loop_nodes.find_by(node_key: @command.task_key)
          return [Result.refused(:task_not_found), false] if node.nil?
          return [Result.refused(:not_awaiting_approval), false] unless node.held?

          # The sweep may not have projected the deadline yet. The park's
          # owner checks its virtual clock and schedules any expiry before
          # a grant can dispatch or re-arm it under a changed profile.
          if Parks::Settle.call(node: node, timeout: true).moved?
            return [Result.refused(:not_awaiting_approval), false]
          end

          worklist = []
          decision = Executors::Address.call(node)
          if decision.refused?
            # The runner the call would go to is gone: the row fails from the
            # stage, `on_failure` honoured, as a start's refusal would.
            FailNode.call(agent_loop: agent_loop, node: node, error_key: decision.error_key,
              error_detail: decision.detail, worklist: worklist)
          else
            self.class.release(agent_loop, node, decision: decision,
              origin: self.class.origin_of(@command.acting_user), approved_by: @command.acting_user)
          end
          [Result.accepted(node), true]
        end
    end
  end
end
