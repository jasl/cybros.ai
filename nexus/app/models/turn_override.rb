# The child's own view-state for an inherited turn: COALESCE(override,
# (visible, not-deleted)), the shared row's columns never consulted. Verbs
# aimed at another conversation's turn write here and never touch the shared row.
class TurnOverride < ApplicationRecord
  attr_readonly :account_id, :conversation_id, :turn_id

  # Both fields stay mutable in both directions, unlike a local turn's
  # tail-constrained restore: an inherited turn is mid-history by construction.

  belongs_to :account, default: -> { conversation&.account }
  belongs_to :conversation
  belongs_to :turn

  validates :visibility, inclusion: { in: Turn::VISIBILITIES }
  validate :turn_is_inherited_within_bounds

  private

    # The referenced turn must belong to a closure ancestor at a position
    # within that ancestor's resolved bound — an override on a local turn (or
    # past the boundary) would be a second place for a fact that has a first.
    def turn_is_inherited_within_bounds
      return if conversation.nil? || turn.nil?
      if turn.conversation_id == conversation_id
        errors.add(:turn, :invalid)
        return
      end

      bound = conversation.conversation_ancestries
        .find_by(ancestor_conversation_id: turn.conversation_id)
        &.boundary_position
      return if bound && turn.position <= bound

      errors.add(:turn, :invalid)
    end
end
