# The create-idempotency receipt for the Workspace family: one row per accepted command,
# written atomically with its effect, replayed verbatim while retained. Controllers own it
# through WorkspaceCommandReceipt::Idempotent.
class WorkspaceCommandReceipt < ApplicationRecord
  include AgeReapable

  IDEMPOTENCY_KEY_MAX_BYTES = 255
  RETENTION = 24.hours

  attr_readonly :account_id, :workspace_id, :acting_user_id, :operation,
    :idempotency_key, :request_digest, :response_status, :response_body

  belongs_to :account
  belongs_to :workspace
  belongs_to :acting_user, class_name: "User"

  enum :operation, %w[workspace_create store_entry_create].index_by(&:itself),
    validate: true, scopes: false

  validates :idempotency_key, presence: true
  validate :idempotency_key_within_byte_bound
  validates :request_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :response_status, presence: true
  validates :response_body, bounded_json: { bound: :workspace_command_response_bound }

  class << self
    # One canonical digest for one accepted request envelope: computed after
    # allowlisting/coercion, key-order independent, and covering the
    # operation, so the same key can never replay across surfaces.
    def digest_for(operation:, envelope:)
      Nexus::CanonicalJson.digest(
        { "operation" => operation.to_s, "envelope" => envelope }
      )
    end
  end

  private

    def idempotency_key_within_byte_bound
      if idempotency_key && idempotency_key.bytesize > IDEMPOTENCY_KEY_MAX_BYTES
        errors.add(:idempotency_key, :too_long, count: IDEMPOTENCY_KEY_MAX_BYTES)
      end
    end
end
