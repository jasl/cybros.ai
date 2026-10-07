# One ordered fragment reference inside a body. Entries are immutable
# because replacement swaps whole entry sets; the unique (body,
# position) index is the ordered-child concurrency winner.
class ContentBodyEntry < ApplicationRecord
  attr_readonly :account_id, :content_body_id, :content_fragment_id, :position

  belongs_to :account
  belongs_to :content_body
  belongs_to :content_fragment

  # A seal freezes membership, not only the body's columns: a sealed request
  # body is the frozen record of the bytes a provider was sent, and an entry
  # appended afterwards would describe something that never crossed the wire.
  validate :parent_body_is_not_sealed, on: :create

  private

    def parent_body_is_not_sealed
      errors.add(:content_body, :sealed) if content_body&.sealed?
    end
end
