# One idempotent append's durable answer, loop-scoped: same key + same digest
# replays this row, a different digest is a 409. Written in the append's own transaction.
class RunAppendReceipt < ApplicationRecord
  include AgeReapable

  RETENTION = 24.hours
  IDEMPOTENCY_KEY_MAX_BYTES = 36

  attr_readonly :account_id, :run_id, :idempotency_key, :request_digest

  belongs_to :account, default: -> { run&.account }
  belongs_to :run, inverse_of: :run_append_receipts

  validates :idempotency_key, presence: true, length: { maximum: 36 },
    uniqueness: { scope: :run_id }
  validates :request_digest, presence: true, length: { maximum: 64 }
  validates :response_status, presence: true

  def self.digest_for(envelope)
    Digest::SHA256.hexdigest(Nexus::CanonicalJson.encode(envelope))
  end
end
