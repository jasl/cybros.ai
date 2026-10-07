module Conversations
  module Variants
    # The deck's conceal/restore (SillyTavern's swipe delete), local turns
    # only: an inherited deck belongs to its own conversation. The active
    # candidate never conceals; a retaken slot refuses restore.
    class SetViewState
      Command = Data.define(:conversation, :turn_public_id, :variant_public_id,
        :acting_user, :concealed)

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
        return Outcome.refused(:nothing_to_change) if @command.concealed.nil?

        @conversation = @command.conversation
        @conversation.with_lock do
          next Outcome.refused(:not_found) if @conversation.tombstoned?
          next Outcome.refused(:conversation_archived) if @conversation.archived?

          turn = @conversation.conversation_turns
            .find_by(public_id: @command.turn_public_id)
          next Outcome.refused(:not_found) if turn.nil? || turn.deleted?

          variant = turn.conversation_turn_variants
            .find_by(public_id: @command.variant_public_id)
          next Outcome.refused(:not_found) if variant.nil?
          # Already in the requested state: a TRUE no-op — no write, no
          # duplicate narration.
          next Outcome.accepted(variant) if @command.concealed == variant.deleted?

          refusal = refusal_for(turn, variant)
          next Outcome.refused(refusal) if refusal

          variant.update!(
            deleted_at: @command.concealed ? Time.current : nil
          )
          @conversation.update!(last_activity_at: Time.current)
          narrate(turn, variant)
          Outcome.accepted(variant)
        end
      end

      private

        # Only consulted for a real state change (no-ops answered above).
        def refusal_for(turn, variant)
          if @command.concealed
            return :not_terminal unless variant.terminal?

            :variant_active if turn.active_variant_id == variant.id
          else
            :slot_occupied if turn.conversation_turn_variants.live
              .where(position: variant.position).exists?
          end
        end

        def narrate(turn, variant)
          ConversationEvent::Append.call(
            host: @conversation,
            items: [{
              type: "turn_variant",
              payload: {
                "turn_public_id" => turn.public_id,
                "variant_public_id" => variant.public_id,
                "concealed" => @command.concealed,
              },
            }]
          )
        end
    end
  end
end
