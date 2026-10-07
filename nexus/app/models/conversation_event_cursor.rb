# The host-local sequence authority. Its lock follows the writer's aggregate
# locks and serializes appenders even when they hold different loop rows.
# Conversation-backed loops do not lock the Conversation to narrate.
class ConversationEventCursor < ApplicationRecord
  attr_readonly :account_id, :host_type, :host_id

  belongs_to :account, default: -> { host&.account }
  belongs_to :host, polymorphic: true

  validates :next_sequence, numericality: { only_integer: true, greater_than: 0 }

  # Returns a contiguous Range of `count` sequences and advances the cursor.
  def allocate_sequences(count)
    raise ArgumentError, "count must be positive" unless count.positive?

    with_lock do
      first_sequence = next_sequence
      update!(next_sequence: first_sequence + count)
      first_sequence...(first_sequence + count)
    end
  end
end
