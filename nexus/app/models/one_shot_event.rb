# One internal append envelope: its only fact is the OneShot-scoped
# idempotency key; identity, timing, payload and sequence belong to the items.
# Written by `OneShotEvents::Append`; dies with its OneShot.
class OneShotEvent < ApplicationRecord
  attr_readonly :account_id, :one_shot_id, :idempotency_key

  belongs_to :account
  belongs_to :one_shot
  has_many :one_shot_event_items, dependent: :delete_all

  validates :idempotency_key, presence: true, length: { maximum: 36 }
end
