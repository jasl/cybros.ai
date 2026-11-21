# One idempotent CREATE's durable answer: the retry that cannot know the
# lost response's loop id finds it here by its own key. Same key + same
# digest replays the standing loop; a different digest is a conflict.
class RunCreateReceipt < ApplicationRecord
  include AgeReapable

  RETENTION = 24.hours
  IDEMPOTENCY_KEY_MAX_BYTES = 255

  attr_readonly :account_id, :workspace_id, :creating_user_id,
    :run_id, :idempotency_key, :request_digest

  belongs_to :account
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"
  belongs_to :run

  validates :idempotency_key, presence: true, uniqueness: { scope: %i[workspace_id creating_user_id] }
  validates :request_digest, presence: true, length: { maximum: 64 }

  validate do
    if idempotency_key && idempotency_key.bytesize > IDEMPOTENCY_KEY_MAX_BYTES
      errors.add(:idempotency_key, :too_long, count: IDEMPOTENCY_KEY_MAX_BYTES)
    end
  end
end
