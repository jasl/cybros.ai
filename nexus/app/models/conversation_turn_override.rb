# The child's own view-state for an inherited turn: COALESCE(override,
# (visible, not-deleted)), the shared row's columns never consulted. Verbs
# aimed at another conversation's turn write here and never touch the shared row.
class ConversationTurnOverride < ApplicationRecord
  attr_readonly :account_id, :conversation_id, :conversation_turn_id

  # Both fields stay mutable in both directions, unlike a local turn's
  # tail-constrained restore: an inherited turn is mid-history by construction.

  belongs_to :account, default: -> { conversation&.account }
  belongs_to :conversation
  belongs_to :conversation_turn

  validates :visibility, inclusion: { in: ConversationTurn::VISIBILITIES }
  validate :turn_is_inherited_within_bounds

  private

    # The referenced turn must belong to a closure ancestor at a position
    # within that ancestor's resolved bound — an override on a local turn (or
    # past the boundary) would be a second place for a fact that has a first.
    def turn_is_inherited_within_bounds
      return if conversation.nil? || conversation_turn.nil?
      if conversation_turn.conversation_id == conversation_id
        errors.add(:conversation_turn, :invalid)
        return
      end

      bound = conversation.conversation_ancestries
        .find_by(ancestor_conversation_id: conversation_turn.conversation_id)
        &.boundary_position
      return if bound && conversation_turn.position <= bound

      errors.add(:conversation_turn, :invalid)
    end
end
