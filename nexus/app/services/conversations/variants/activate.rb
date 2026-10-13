module Conversations
  module Variants
    # The swipe switch, tail-only like every content verb; re-activating
    # the active candidate is an event-free no-op.
    class Activate
      Command = Data.define(:conversation, :turn_public_id, :variant_public_id,
        :acting_user)

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
          next Outcome.refused(:not_found) if turn.nil? || turn.deleted?
          next Outcome.refused(:branch_required) unless turn.tail?
          next Outcome.refused(:conversation_busy) unless turn.terminal?

          variant = turn.conversation_turn_variants
            .find_by(public_id: @command.variant_public_id)
          next Outcome.refused(:not_found) if variant.nil? || variant.deleted?
          next Outcome.accepted(variant) if turn.active_variant_id == variant.id
          next Outcome.refused(:variant_not_active) unless variant.completed?

          source = turn.active_variant&.agent_run
          AgentRuns::Stop.mark_now(source) if source
          turn.update!(active_variant: variant, status: variant.status)
          @conversation.update!(
            context_revision: @conversation.context_revision + 1,
            last_activity_at: Time.current
          )
          narrate(turn, variant)
          Outcome.accepted(variant)
        end
      end

      private

        def narrate(turn, variant)
          agent_run = variant.agent_run
          identity = {
            "turn_public_id" => turn.public_id,
            "variant_public_id" => variant.public_id,
            "run_public_id" => agent_run&.public_id,
          }.compact
          ConversationEvent::Append.call(
            host: @conversation,
            items: [
              { type: "turn_variant", payload: identity.merge("activated" => true) },
              {
                type: "turn_status",
                payload: identity.merge(
                  "turn_kind" => turn.kind, "status" => turn.status, "variant_status" => variant.status
                ),
              },
            ]
          )
          TranscriptStream.settled_turn(turn, variant: variant, agent_run: agent_run)
        end
    end
  end
end
