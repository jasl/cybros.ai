# The internal append envelope of the conversation-own event plane: one row
# per append, grouping public items; identity/timing/payload belong to the
# items. Rows die with their host, children first.
class ConversationEvent < ApplicationRecord
  attr_readonly :account_id, :host_type, :host_id, :idempotency_key

  belongs_to :account
  belongs_to :host, polymorphic: true

  has_many :conversation_event_items, dependent: :delete_all

  validates :idempotency_key, presence: true, length: { maximum: 36 }
end
