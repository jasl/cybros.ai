module Conversations
  module Turns
    # Stops every execution owned by this conversation, including delivered
    # turns' background work. The durable cut is committed on those existing
    # loops; their own scheduler and the request relay drain derived work later.
    # Child conversations are reusable containers, never cancellation owners.
    class Cancel
      Command = Data.define(:conversation, :acting_user)

      class << self
        def call(command)
          new(command).call
        end

        # THE KERNEL'S OWN ACT: the locked path with no standing gate and
        # no acting user — the verb that reached here (a side's DELETE, the
        # parent's cascade) passed standing already. The converger kick
        # stays with the caller.
        def stop_now(conversation)
          new(Command.new(conversation: conversation, acting_user: nil)).stop_now
        end

        # The kernel's act over this conversation's request ownership tree
        # (the `cancel` tool reaches here too).
        def stop_tree(conversation)
          new(Command.new(conversation: conversation, acting_user: nil)).stop_tree
        end
      end

      def initialize(command)
        @command = command
      end

      def call
        unless @command.conversation.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        result = stop_tree
        Conversations::Turns::ConvergeJob.perform_later if result.accepted?
        result
      end

      def stop_now
        result = @command.conversation.with_lock { locked_cancel }
        if result.accepted?
          AgentLoops::ScheduleSweepJob.perform_later
          AgentLoops::Spawn::RelayJob.perform_later
        end
        result
      end

      # Retained as the kernel caller's entry point: the tree is now the
      # request ownership tree, drained from sender stamps, not child grouping.
      def stop_tree = stop_now

      private

        def locked_cancel
          conversation = @command.conversation
          return Outcome.refused(:not_found) if conversation.tombstoned?

          # One set-based authority cut, under the owning conversation lock.
          # Materialization also owns that lock, so later independent inputs
          # create unstopped loops. No child aggregate is touched here, and
          # callback-free writes have explicit wakes plus recurring recovery.
          variants = ConversationTurnVariant.where(conversation_turn_id: conversation.conversation_turns.select(:id))
          @cut_count = AgentLoop.where(conversation_turn_variant_id: variants.select(:id), stopped_at: nil)
            .update_all(stopped_at: Time.current)

          turn = ApplicationRecord.uncached do
            conversation.conversation_turns.active.first
          end
          return stop_held_tail(conversation) if turn.nil?

          variant = turn.conversation_turn_variants
            .where(status: ConversationTurnVariant::ACTIVE_STATUSES)
            .order(:position).last
          invocation = variant&.model_invocation
          agent_loop = variant&.agent_loop

          if agent_loop
            # The loop drains to its terminal and the converger settles the turn.
            AgentLoops::Stop.stop_now(agent_loop)
          elsif invocation
            invocation.lock!
            invocation.terminalize(status: "canceled", reason_key: "creator_requested")
            # The converger applies the terminal to the timeline — except a
            # DECLINED or OVERLOADED answer's, already terminal before the
            # stop and not yet recorded: the converger would re-ask it on the
            # answerer's fallback, so it settles here with no switch.
            if invocation.undecided?
              Converge.settle_now(conversation, invocation, variant)
            end
          else
            # Defensive: an active turn with no invocation settles directly.
            variant&.update!(status: "canceled")
            turn.update!(status: "canceled")
            conversation.update!(active_turn: nil, last_activity_at: Time.current)
            Inputs::ReleaseSteers.call(host: conversation, inputs: turn.steering_inputs)
            narrate(conversation, turn, variant)
          end
          Outcome.accepted
        end

        # A hold settled the turn but its loop is still adjudicable: this is
        # the chat-shaped client's one door to release it before the apex
        # undo (`loop_live`). The variant stays as it settled.
        def stop_held_tail(conversation)
          tail = conversation.conversation_turns.order(:position).last
          agent_loop = tail&.live_agent_loop
          return @cut_count.positive? ? Outcome.accepted : Outcome.refused(:not_running) if agent_loop.nil?

          AgentLoops::Stop.stop_now(agent_loop)
          Outcome.accepted
        end

        def narrate(conversation, turn, variant)
          ConversationEvent::Append.call(
            host: conversation,
            items: [{
              type: "turn_status",
              payload: {
                "turn_public_id" => turn.public_id,
                "turn_kind" => turn.kind,
                "variant_public_id" => variant&.public_id,
                "status" => "canceled",
              }.compact,
            }]
          )
        end
    end
  end
end
