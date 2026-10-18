# Private replay evidence for one accepted InferenceRequest create, storing an
# HTTP-neutral domain result so no adapter's shape leaks into a row.
class InferenceRequestCreateReceipt < ApplicationRecord
  include AgeReapable

  IDEMPOTENCY_KEY_MAX_BYTES = 255
  RETENTION = 24.hours

  attr_readonly :account_id, :workspace_id, :acting_user_id, :inference_request_id,
    :workload, :idempotency_key, :request_digest, :result

  belongs_to :account
  belongs_to :workspace
  belongs_to :acting_user, class_name: "User"
  belongs_to :inference_request

  before_validation :derive_inference_request_scope, on: :create

  validates :idempotency_key, presence: true
  validate :idempotency_key_within_byte_bound
  validates :request_digest, presence: true
  validates :workload, presence: true
  validates :workload, inclusion: { in: Nexus::ModelWorkloads::ALL }, allow_nil: true
  validates :result, bounded_json: { bound: :envelope_bound }

  class << self
    # The digest covers the normalized accepted command before selection or
    # mutation. Replay can therefore compare one stable, workload-scoped
    # identity without attempting to reconstruct caller input from InferenceRequest.
    def digest_for(workload:, envelope:)
      Nexus::CanonicalJson.digest(
        { "workload" => workload.to_s, "envelope" => envelope }
      )
    end
  end

  private

    # Everything a replay says comes from the durable target: replay answers
    # without re-checking, so a caller may supply none of it.
    def derive_inference_request_scope
      if inference_request
        self.account = inference_request.account
        self.workspace = inference_request.workspace
        self.acting_user = inference_request.creating_user
        self.workload = inference_request.workload
        self.result = {
          "inference_request_public_id" => inference_request.public_id.to_s,
          "workload" => inference_request.workload,
        }
      end
    end

    def idempotency_key_within_byte_bound
      if idempotency_key && idempotency_key.bytesize > IDEMPOTENCY_KEY_MAX_BYTES
        errors.add(:idempotency_key, :too_long, count: IDEMPOTENCY_KEY_MAX_BYTES)
      end
    end
end
