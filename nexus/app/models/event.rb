# The append envelope shared by User, Conversation and Run event hosts.
# Each append groups public items, which own identity, timing and payload.
# Rows die with their host, children first.
class Event < ApplicationRecord
  attr_readonly :account_id, :host_type, :host_id, :idempotency_key

  belongs_to :account
  belongs_to :host, polymorphic: true

  has_many :event_items, dependent: :delete_all

  validates :idempotency_key, presence: true, length: { maximum: 36 }
end
