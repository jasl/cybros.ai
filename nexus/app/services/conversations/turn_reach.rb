module Conversations
  # Resolves a turn through the conversation's read reach, the lattice the
  # timeline funnel serves, and says which side of the boundary it lives on:
  # a local row owns its columns, an inherited one is touched only through overrides.
  module TurnReach
    Resolution = Data.define(:turn, :inherited) do
      def inherited? = inherited
    end

    module_function

    def resolve(conversation:, turn_public_id:)
      turn = ConversationTurn.find_by(public_id: turn_public_id)
      return nil if turn.nil?

      if turn.conversation_id == conversation.id
        Resolution.new(turn: turn, inherited: false)
      else
        bound = conversation.conversation_ancestries
          .find_by(ancestor_conversation_id: turn.conversation_id)&.boundary_position
        return nil if bound.nil? || turn.position > bound

        Resolution.new(turn: turn, inherited: true)
      end
    end
  end
end
