# Idempotency for create / input_create / fork / store_entry_create: same
# key + same digest replays the stored response, a mismatch is 409; the
# host pair is a weak reference (no FK), so a receipt never blocks reap.
class ConversationCommandReceipt < ApplicationRecord
  include AgeReapable

  OPERATIONS = %w[conversation_create input_create fork store_entry_create scheduled_job_create].freeze
  RETENTION = 24.hours

  attr_readonly :account_id, :workspace_id, :host_type, :host_id, :acting_user_id,
    :operation, :idempotency_key, :request_digest, :response_status,
    :response_body

  belongs_to :account
  belongs_to :workspace
  # Null for conversation_create until the created row fills it.
  belongs_to :host, polymorphic: true, optional: true
  belongs_to :acting_user, class_name: "User"

  validates :operation, inclusion: { in: OPERATIONS }
  validates :idempotency_key, presence: true
  validates :request_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :response_status, presence: true

  # An input receipt preserves the complete accepted prompt for exact replay.
  # Its input and compiled-request boundaries own content limits; applying the
  # metadata response ceiling here would reject otherwise valid long prompts.
  validates :response_body, bounded_json: { bound: :workspace_command_response_bound, shape: Hash },
    unless: -> { %w[input_create scheduled_job_create].include?(operation) }

  class << self
    # One digest discipline for every operation on this surface, mirroring
    # WorkspaceCommandReceipt: canonical, key-order independent, covering the
    # operation so a key can never replay across surfaces.
    def digest_for(operation:, envelope:)
      Nexus::CanonicalJson.digest(
        { "operation" => operation.to_s, "envelope" => envelope }
      )
    end
  end
end
