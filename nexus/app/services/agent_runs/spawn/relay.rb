module AgentRuns
  module Spawn
    # THE CHILD-REPLY RELAY: a
    # spawned child's settled reply reaches its parent exactly once,
    # LEVEL-TRIGGERED over durable state — the spawned children
    # (`spawn_node_id` present) and, per child, its terminal `direct_reply`
    # turns not yet stamped `relayed_at`. The converger's kick at both
    # turn terminals is a latency hint; the recurring sweep is the floor;
    # a lost enqueue loses nothing.
    #
    # Per turn: owed only when the PARENT opened it (the seed's sender
    # stamp is the parent's — the brief and every parent `send`); a
    # person's or a third agent's exchange in the child is theirs and is
    # stamped "nothing owed". A CASCADE CANCEL OWES NOTHING:
    # when the parent turn that opened it was itself stopped unanswered —
    # the same tree stop, a person's cancel above — the reply is stamped
    # too, so a grandchild's canceled reply never wakes the canceled child
    # as a new turn; the canceller, its own turn running, is still owed
    # what it canceled. Only the original spawn request takes the AWAIT
    # path when its kernel-held await is parked (settled TRUSTED, the settle and
    # the stamp one transaction, the narration naming the resolver), is
    # DEFERRED while the await exists but is not yet a park, and takes the
    # MAIL path otherwise. A later send always mails its own execution,
    # even when the original await still waits (`ResultDelivery.child_reply`, whose receipt is the inner
    # guard and whose stamp rides its transaction). A parent that is gone
    # owes nothing; a full queue is retried on the sweep's clock.
    class Relay
      BUDGET = 200
      OWED_KINDS = { kind: "direct_reply", role: "assistant" }.freeze

      def self.call(...) = new(...).call

      # Guarded, never locked (`conversation_turns` is off the ladder):
      # the marker is not a status, and both paths write it once.
      def self.stamp(turn) = turn.stamp_relayed

      def initialize(conversation_id: nil, after_id: 0, delegation_after_id: 0,
                     children_done: false, delegations_done: false, budget: BUDGET,
                     input_after_id: 0, variant_after_id: 0, inputs_done: false, variants_done: false)
        @conversation_id = conversation_id
        @after_id = after_id.to_i
        @delegation_after_id = delegation_after_id.to_i
        @children_done, @delegations_done = children_done, delegations_done
        @budget = budget
        @input_after_id, @variant_after_id = input_after_id, variant_after_id
        @inputs_done, @variants_done = inputs_done, variants_done
      end

      def call
        children = frontier
        relayed = children.sum { |child_id| relay_child(child_id) }
        delegated = delegation_frontier
        completed = delegated.count { |node| converge_delegation(node) }
        inputs = source_window(ConversationInput.where.not(sender_run_public_id: nil),
          @input_after_id, @inputs_done)
        variants = source_window(ConversationTurnVariant.where(deleted_at: nil,
          status: ConversationTurnVariant::ACTIVE_STATUSES + ["failed"]), @variant_after_id, @variants_done)
        canceled = inputs.count { |id| recover_source(:input, id) } + variants.count { |id| recover_source(:variant, id) }
        more_children = !@conversation_id && !@children_done && children.length == @budget
        more_delegations = !@conversation_id && !@delegations_done && @delegation_ids.length == @budget
        Sweeps::Pass.new(
          counts: { relayed: relayed + completed, canceled: canceled,
                    scanned: children.length + @delegation_ids.length + inputs.length + variants.length },
          cursor: {
            "after_id" => children.last || @after_id,
            "delegation_after_id" => @delegation_ids.last || @delegation_after_id,
            "children_done" => !more_children, "delegations_done" => !more_delegations,
            "input_after_id" => inputs.last || @input_after_id,
            "variant_after_id" => variants.last || @variant_after_id,
            "inputs_done" => inputs.length < @budget, "variants_done" => variants.length < @budget,
          },
          more: more_children || more_delegations || inputs.length == @budget || variants.length == @budget
        )
      end

      private

        def source_window(scope, after_id, done)
          return [] if @conversation_id || done || !@budget.positive?

          scope.where(id: (after_id + 1)..).order(:id).limit(@budget).pluck(:id)
        end

        def recover_source(kind, id)
          SourceWork::Recovery.public_send(kind, id)
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "source_work_recovery_failed", source_kind: kind, source_id: id })
          false
        end

        # Lock-free, keyset by id over the unique partial index of
        # `spawn_node_id`; one child when the kick names it.
        def frontier
          return [] if @children_done

          scope = Conversation.where.not(spawn_node_id: nil).or(Conversation.where.not(schedule_id: nil))
          return scope.where(id: @conversation_id).pluck(:id) if @conversation_id

          scope.where(id: (@after_id + 1)..).order(:id).limit(@budget).pluck(:id)
        end

        def delegation_frontier
          @delegation_ids = []
          return [] if @conversation_id || @delegations_done

          @delegation_ids = Delegations.recovery_candidates(after_id: @delegation_after_id, limit: @budget).pluck(:id)
          AgentRunTask.where(id: @delegation_ids).order(:id).to_a
        end

        def converge_delegation(node)
          Delegations.converge(node: node)
        rescue StandardError => error
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "delegation_relay_failed", run_public_id: node.agent_run.public_id,
                       task_key: node.node_key })
          false
        end

        def relay_child(child_id)
          child = Conversation.find_by(id: child_id)
          return 0 if child.nil?

          completion = Delegations::Converge.call(child: child) if @conversation_id
          (completion ? 1 : 0) + unrelayed_replies(child).count { |turn| relay_turn(child, turn) }
        rescue StandardError => error
          # The poison-row lesson: one unrelayable child must not abort the
          # batch. Its turns stay on the frontier and the next pass retries.
          Rails.error.report(error, handled: true, severity: :error,
            context: { event: "spawn_reply_relay_failed", conversation_id: child_id })
          0
        end

        def unrelayed_replies(child)
          scope = child.conversation_turns.where(**OWED_KINDS, relayed_at: nil)
          replies = scope.live.where(status: ConversationTurn::TERMINAL_STATUSES)
          if child.scheduled_execution?
            # The occurrence owns its original sample even if the visible
            # turn is concealed or a later regeneration is still running.
            replies = replies.or(scope.where(public_id: child.scheduled_turn_public_id))
          end
          replies.order(:position).select do |turn|
            !scheduled_reply?(child, turn) || Schedules::Execution.ready_for_reply?(turn)
          end
        end

        def scheduled_reply?(child, turn)
          child.scheduled_execution? && child.scheduled_turn_public_id == turn.public_id
        end

        # True when the turn left the frontier: delivered, or nothing owed.
        def relay_turn(child, turn)
          if scheduled_reply?(child, turn)
            result = ResultDelivery.scheduled_reply(child: child, turn: turn)
            return stamp(turn) if [:not_found, :source_stopped].include?(result)

            return result == :delivered
          end

          call = child.spawn_node
          # The completion owner observes the original execution even while
          # its visible Turn is failed, concealed, edited or regenerating.
          # It stamps that report atomically; it must never become later mail.
          return false if Delegations.for_dispatch(child,
            turn.sender_run_public_id, turn.sender_task_key)

          sender_loop = reply_owner(turn, child, call)
          return stamp(turn) if sender_loop.nil?

          TaskWaits.wake_observers(sender_loop)

          case await_path(call, child, turn, sender_loop)
          when :deferred then false
          when :applied then true
          else result_delivery_path(sender_loop, child, turn)
          end
        end

        # Every request keeps the loop that sent it, independently of the
        # child's original spawn. A stopped request owes no reply, but a later
        # send to that persistent child does and owns the receiving Agent and
        # request surface. Steers share the existing turn's frozen obligation.
        # Weak source stamps add no retention dependency; an absent source or
        # task key cannot establish an owed reply and is never guessed from history.
        def reply_owner(turn, child, call)
          return unless call.present? || child.scheduled_execution?

          parent = child.parent_conversation
          return unless parent.present? && turn.sender_task_key.present? &&
            turn.sender_conversation_public_id == parent.public_id

          sender_loop = AgentRun.find_by(public_id: turn.sender_run_public_id)
          sender_loop unless SourceWork.stopped?(turn.sender_run_public_id, sender_loop) ||
            sender_loop&.canceled_unanswered?
        end

        # `:applied` settles the await and stamps the turn in ONE
        # transaction (a death between the two would let the sweep find
        # the await terminal and mail a second copy); `:deferred` while
        # the await is appended but not yet parked by the scheduler —
        # settling it now would be refused, mailing it now would leave the
        # await to expire against a reply already delivered; anything else
        # (no await, expiry, a terminal one, a refusal) is the mail path's.
        # The loop arbiter owns the delivery check too: an overlapping
        # relay must see the stamp before choosing mail. Settle can apply
        # an expiry without accepting the reply; that reply is still owed.
        def await_path(call, child, turn, sender_loop)
          # A loop may spawn and send again before the first reply. Both
          # request stamps must match: only the brief can answer this await.
          return :mail unless call && call.agent_run_id == sender_loop.id && call.node_key == turn.sender_task_key

          await = call.spawn_await
          return :mail if await.nil?

          await.agent_run.with_lock do
            next :applied if turn.reload.relayed_at
            next :applied if SourceWork.stopped?(sender_loop.public_id, sender_loop.reload) && stamp(turn)
            next :mail if await.reload.terminal?
            next :deferred unless await.started?

            result = Parks::Settle.call(
              node: await, trusted: true, content: ResultDelivery.reply_text(turn),
              outcome: (turn.completed? ? "completed" : "failed"),
              resolved_by: { "kind" => "conversation", "public_id" => child.public_id }
            )
            next :mail unless result.applied? && result.node.status != "timed_out"

            self.class.stamp(turn)
            :applied
          end
        end

        # `not_found` (the parent tombstoned) stamps — nothing is owed to a
        # conversation that is gone; every other refusal (`input_queue_full`,
        # a suspended creator's standing) leaves the turn for the next pass.
        def result_delivery_path(sender_loop, child, turn)
          case ResultDelivery.child_reply(agent_run: sender_loop, child: child, turn: turn)
          when :delivered then true
          when :not_found, :source_stopped then stamp(turn)
          else false
          end
        end

        def stamp(turn)
          self.class.stamp(turn)
          true
        end
    end
  end
end
