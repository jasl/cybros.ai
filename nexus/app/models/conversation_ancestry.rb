# One row per ancestor in a fork's materialized closure: the child copies its
# parent's closure capped at the new edge, so nothing recurses at fork or at
# read. `boundary_position` is inclusive; the RESTRICT FK enforces leaves-first reap.
class ConversationAncestry < ApplicationRecord
  attr_readonly :account_id, :conversation_id, :ancestor_conversation_id,
    :depth, :boundary_position

  belongs_to :account
  belongs_to :conversation
  belongs_to :ancestor_conversation, class_name: "Conversation"

  validates :depth, numericality: { only_integer: true, greater_than: 0 }
  # -1 is the empty prefix: a fork at position 0 reads NOTHING from this
  # ancestor (bound = P-1 = -1) and still records the lineage pin.
  validates :boundary_position, numericality: { only_integer: true, greater_than_or_equal_to: -1 }
  validate :ancestor_must_share_the_workspace
  validate :never_its_own_ancestor

  private

    def ancestor_must_share_the_workspace
      return if ancestor_conversation.nil? || conversation.nil?
      return if ancestor_conversation.workspace_id == conversation.workspace_id

      errors.add(:ancestor_conversation, :invalid)
    end

    # Structural under the copy-the-parent's-closure construction (the parent's
    # closure cannot contain the child), kept as a validation so a hand-built
    # row cannot create a cycle either.
    def never_its_own_ancestor
      errors.add(:ancestor_conversation, :invalid) if
        conversation_id.present? && conversation_id == ancestor_conversation_id
    end
end
