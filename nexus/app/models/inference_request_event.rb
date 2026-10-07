# One internal append envelope: its only fact is the InferenceRequest-scoped
# idempotency key; identity, timing, payload and sequence belong to the items.
# Written by `InferenceRequestEvents::Append`; dies with its InferenceRequest.
class InferenceRequestEvent < ApplicationRecord
  attr_readonly :account_id, :inference_request_id, :idempotency_key

  belongs_to :account
  belongs_to :inference_request
  has_many :inference_request_event_items, dependent: :delete_all

  validates :idempotency_key, presence: true, length: { maximum: 36 }
end
