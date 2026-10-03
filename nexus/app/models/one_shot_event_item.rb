# One durable item in a OneShot's replay stream, sequenced OneShot-locally
# and contiguously (the cursor allocates, the unique index arbitrates). The
# type vocabulary is only what this plane can emit.
class OneShotEventItem < ApplicationRecord
  ITEM_TYPES = %w[
    run_status
    text_delta
    reasoning_delta
    provider_output_item_started
    provider_output_item_delta
    provider_output_item_completed
    usage
    result
    rollback
  ].freeze

  attr_readonly :account_id, :one_shot_event_id, :one_shot_id, :public_id,
    :sequence, :item_type, :occurred_at

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :one_shot_event
  belongs_to :one_shot

  scope :after_sequence, ->(sequence) { where(sequence: (sequence + 1)..) }

  validates :item_type, inclusion: { in: ITEM_TYPES }
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
  validates :occurred_at, presence: true

  validates :payload, bounded_json: { bound: :envelope_bound }
end
