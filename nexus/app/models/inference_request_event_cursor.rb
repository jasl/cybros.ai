# The InferenceRequest-local sequence allocator: its row lock makes a multi-item
# append contiguous — constraints reject collisions but cannot reserve
# ranges. Last on the lock ladder.
class InferenceRequestEventCursor < ApplicationRecord
  attr_readonly :account_id, :inference_request_id

  belongs_to :account
  belongs_to :inference_request

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
