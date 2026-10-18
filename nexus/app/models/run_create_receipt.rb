# One idempotent CREATE's durable answer: the retry that cannot know the
# lost response's loop id finds it here by its own key. Same key + same
# digest replays the standing loop; a different digest is a conflict.
class RunCreateReceipt < ApplicationRecord
  include AgeReapable

  RETENTION = 24.hours

  attr_readonly :account_id, :workspace_id, :creating_user_id,
    :run_id, :idempotency_key, :request_digest

  belongs_to :account
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"
  belongs_to :run

  validates :idempotency_key, presence: true, length: { maximum: 36 },
    uniqueness: { scope: %i[workspace_id creating_user_id] }
  validates :request_digest, presence: true, length: { maximum: 64 }
end
