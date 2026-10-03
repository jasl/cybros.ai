module Conversations
  module Turns
    # Only the apex hard-deletes, under the conversation lock that
    # serializes it against fork; each refusal names its cause. The vacated
    # slot never refills: the head never decrements.
    class HardDelete
      Command = Data.define(:conversation, :turn_public_id, :acting_user)

      class << self
        def call(command)
          new(command).call
        end
      end

      def initialize(command)
        @command = command
      end

      def call
        unless @command.conversation.writable_by?(@command.acting_user)
          return Outcome.refused(:not_authorized)
        end

        @conversation = @command.conversation
        @conversation.with_lock do
          next Outcome.refused(:not_found) if @conversation.tombstoned?
          next Outcome.refused(:conversation_archived) if @conversation.archived?

          turn = @conversation.conversation_turns
            .find_by(public_id: @command.turn_public_id)
          next Outcome.refused(:not_found) if turn.nil?

          refusal = refusal_for(turn)
          next refusal if refusal

          position = turn.position
          public_id = turn.public_id
          was_in_assembly = !turn.deleted? && turn.visibility == "visible"
          # A loop whose seam is nil is a tombstoned loop by
          # construction: the undo tombstones first, then the FK
          # nullifies.
          turn.agent_loops.each { |agent_loop| AgentLoops::Tombstone.call(agent_loop: agent_loop) }
          turn.destroy!

          @conversation.update!(
            last_activity_at: Time.current,
            **(was_in_assembly ?
              { context_revision: @conversation.context_revision + 1 } : {})
          )
          narrate(public_id, position)
          Outcome.accepted
        end
      end

      private

        def refusal_for(turn)
          if @conversation.conversation_turns.above(turn.position).exists?
            return Outcome.refused(:apex_only)
          end
          return Outcome.refused(:not_terminal) unless turn.terminal?
          return Outcome.refused(:delegation_pending) if AgentLoops::Delegations.owed_result?(turn)
          # A hold-settled turn is terminal while its loop still lives;
          # cascading it would leave an adjudicable loop hosting itself.
          return Outcome.refused(:loop_live) if turn.live_agent_loop

          pin = ConversationAncestry
            .where(ancestor_conversation_id: @conversation.id, boundary_position: turn.position..)
            .first
          if pin
            return Outcome.refused(:descendant_pinned, pin.conversation.public_id)
          end

          if turn.steering_inputs.exists?
            Outcome.refused(:steering_holds)
          end
        end

        def narrate(public_id, position)
          ConversationEvent::Append.call(
            host: @conversation,
            items: [{
              type: "turn_deleted",
              payload: {
                "turn_public_id" => public_id,
                "position" => position,
              },
            }]
          )
        end
    end
  end
end
