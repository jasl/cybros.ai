module AgentLoops
  # The one closed quiescence site: every terminal path routes here under
  # the loop lock, and a canceling loop drains here. Level-triggered, so
  # any wake is safe.
  class EvaluateQuiescence
    # The one ask with nothing gone wrong: a model composed a question.
    ASKING_REASON = "awaiting_human".freeze
    # A tool call resting for an approver: nothing wrong either, and the
    # loop stays `running` — waiting is not halting.
    APPROVAL_REASON = "approval_required".freeze

    class << self
      def call(agent_loop)
        if !agent_loop.terminal? && !agent_loop.canceling? &&
            (agent_loop.stopped? || SourceWork.stopped_source?(agent_loop))
          # A settle may already hold a body or event cursor. Stop under the
          # next scheduler's loop lock, before its invocation/body suffix;
          # this pass must neither wake nor publish the stopped execution.
          ScheduleJob.perform_later(agent_loop.id)
          return
        end

        case agent_loop.status
        when "running" then evaluate_running(agent_loop)
        when "canceling" then evaluate_canceling(agent_loop)
        else nil
        end
      end

      private

        def evaluate_running(agent_loop)
          # An unread turn-owned answer still constrains final delivery:
          # the wake appends a round to consume it. Conversation-lifetime
          # background results wait for Mail after this reply becomes final.
          return if WakeContinuation.call(agent_loop: agent_loop)
          # A loop whose compaction delegate expired unanswered still owes
          # a summary: the kernel's own summarizer is appended once, here,
          # under the same lock every settle and the sweep already hold —
          # the same shape as the wake above.
          return if Conversations::Compaction::Arm.fallback(agent_loop)

          nodes = agent_loop.agent_loop_nodes.where(status: AgentLoopNode::LIVE_STATUSES).to_a
          # Started, not live: only begun work holds a loop open. Counting
          # `queued` here would kill the starvation arm and the announce split.
          started = nodes.select(&:started?)

          # A model's question announces from `running` — a parked await is a
          # running node, but nothing else will tell a person. Only the asks
          # nobody holds a key to: a client-authored await already has its token.
          # `started` whole: a parked question inside an orphan is still a
          # question a console lists.
          if asking?(started)
            announce_ask(agent_loop)
          else
            clear_ask(agent_loop)
          end

          # Detached turn-owned work still owes its result before final.
          # Conversation-lifetime background work is delivered after this reply;
          # standalone loops have no later Turn and await all their work.
          background = agent_loop.standalone? ? [] : nodes.select do |node|
            node.detached? && node.lifetime == "conversation"
          end

          # The approval arm, over ALL LIVE WORK: a row resting for an
          # approver announces wherever it sits — a detached branch's call
          # too — never over a standing reason; a FOREGROUND held row keeps
          # the reply un-final exactly as started foreground work does; the
          # announcement clears only when no held row is left, so a
          # background hold after delivery keeps its word.
          held = nodes.select(&:held?)
          if held.any?
            announce_hold(agent_loop)
          else
            clear_hold(agent_loop)
          end
          return if (held - background).any?
          return if (started - background).any?
          return if nodes.any? do |node|
            node.status == "queued" && node.remaining_dependencies.zero? && !background.include?(node)
          end

          unresolved = unresolved_failure?(agent_loop)
          # A node nothing will schedule holds the loop with a reason rather
          # than letting it complete out from under the hold. A queued row
          # behind a live orphan is that orphan's next round, not starvation.
          # A held row is never starvation: it waits on an approver, not on
          # a scheduler that will not come (and a foreground one returned above).
          starved = nodes.any? do |node|
            AgentLoopNode::PRE_DISPATCH_STATUSES.include?(node.status) && !node.held? && !background.include?(node)
          end

          # The answer can already be completed, outside the live frontier.
          # Read it afresh: another instance may have settled it in this transaction.
          deliverable = agent_loop.agent_loop_nodes.find_by(id: agent_loop.deliverable_node_id)
          if unresolved || starved
            hold(agent_loop, "halt_failure")
          elsif deliverable&.status == "completed"
            # A word nobody has read yet is one more round, not an answer —
            # while the reply is not yet final.
            return if agent_loop.delivered_at.nil? && plant_follow_up(agent_loop, deliverable)

            return if LifecycleHooks.before_delivery(agent_loop, deliverable)

            deliver(agent_loop, background)
          else
            hold(agent_loop, "deliverable_unresolved")
          end
        end

        # Only unadjudicated halt failures can remain pending after a terminal
        # write. The graph still decides whether a settled race absorbed them.
        def unresolved_failure?(agent_loop)
          agent_loop.agent_loop_nodes
            .where(status: AgentLoopNode::FAILURE_STATUSES, on_failure: "halt", failure_resolution: nil)
            .includes(outgoing_edges: :to_node)
            .any? { |node| Graph.settlement_of(node) == :pending }
        end

        # The reply is final: `delivered_at` once; `completed` only when
        # nothing remains, with no announce-split stamp surviving onto the
        # completed record. A background hold's word STANDS across the
        # delivery: a background question or approval keeps its attention
        # reason until its row leaves. A settled orphan is mailed after commit
        # — the door takes the conversation lock, which the loop lock must
        # never hold.
        def deliver(agent_loop, background)
          stamps = agent_loop.delivered_at.nil? ? { delivered_at: Time.current } : {}
          if background.empty?
            Transition.agent_loop(agent_loop, status: "completed",
              completed_at: Time.current, attention_reason: nil, **stamps)
          elsif stamps.any?
            Transition.agent_loop(agent_loop, **stamps)
          end
          MailJob.perform_later(agent_loop.id) if Mail.pending?(agent_loop)
        end

        # An undrained input plants one more spine round: the queue head
        # binds, one kernel continuation follows the deliverable round, and
        # the bound rows drain into it at its peek. A halt keeps the queue
        # waiting; only a loop about to complete plants.
        def plant_follow_up(agent_loop, deliverable)
          return false unless agent_loop.graph_mutable? && deliverable.round?

          bound = bind_follow_up_head(agent_loop)
          return false unless bound || agent_loop.steering_inputs.exists?
          return false if WakeContinuation.plant(agent_loop: agent_loop, source: deliverable).nil?

          ScheduleJob.perform_later(agent_loop.id)
          true
        end

        # One head per boundary — the FIFO rule ApplyNext keeps for turns.
        # The reason names the kernel as the writer, as the release's does.
        def bind_follow_up_head(agent_loop)
          head = agent_loop.follow_up_inputs.first
          return false if head.nil?

          head.update!(state: "steering")
          AgentLoop::Narration.record(agent_loop, [{
            type: "input_edited",
            payload: {
              "input_public_id" => head.public_id,
              "queue_position" => head.queue_position,
              "state" => "steering",
              "reason" => "follow_up_bound",
            },
          }])
          true
        end

        # A parked await that answers to write standing — the shape a
        # model's `g.ask` produces — is a question with nobody assigned
        # to it; the row answers for itself.
        def asking?(started) = started.any?(&:asking?)

        # Never over a stamp that is already standing: a halt failure is
        # the more urgent ask and must not be replaced by this one.
        def announce_ask(agent_loop)
          return if agent_loop.attention_reason.present?

          Transition.agent_loop(agent_loop, attention_reason: ASKING_REASON)
        end

        # A stale ask is worse than none — it is what a console renders as
        # something a human must do. Only this reason is cleared here;
        # a halt failure clears on its own terms below.
        def clear_ask(agent_loop)
          return unless agent_loop.attention_reason == ASKING_REASON

          Transition.agent_loop(agent_loop, attention_reason: nil)
        end

        # The ask's rule, for the hold: never over a standing reason (a halt
        # failure, a question) — the more urgent word stands.
        def announce_hold(agent_loop)
          return if agent_loop.attention_reason.present?

          Transition.agent_loop(agent_loop, attention_reason: APPROVAL_REASON)
        end

        def clear_hold(agent_loop)
          return unless agent_loop.attention_reason == APPROVAL_REASON

          Transition.agent_loop(agent_loop, attention_reason: nil)
        end

        def evaluate_canceling(agent_loop)
          # The drain waits on started work only, parks included; waiting on
          # `queued` would wedge every graceful stop, since the sweep below clears those.
          return if agent_loop.agent_loop_nodes.where(status: AgentLoopNode::STARTED_STATUSES).exists?

          # The drain's own sweep: whatever slipped back to queued while
          # the loop was dying settles with it — a canceled loop never
          # carries live-looking work.
          Stop.cancel_unstarted_nodes(agent_loop)
          Transition.agent_loop(agent_loop, status: "canceled", completed_at: Time.current)
        end

        # No clock on a hold: the human round waits indefinitely, so no
        # base timestamp either.
        def hold(agent_loop, reason)
          Transition.agent_loop(
            agent_loop,
            status: "needs_attention",
            attention_reason: reason
          )
        end
    end
  end
end
