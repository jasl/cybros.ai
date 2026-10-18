class McpConnection::OAuthData
  include StoreModel::Model

  MAX_BYTES = 65_536
  AUTHORIZATION_SECONDS = 600
  OPERATION_SECONDS = 30

  class Operation
    include StoreModel::Model

    attribute :id, :string
    attribute :kind, :string
    attribute :deadline_at, :datetime
    attribute :owner_authority_generation, :integer

    validates :id, :deadline_at, :owner_authority_generation, presence: true
    validates :kind, inclusion: { in: %w[start finish refresh] }
  end

  class PendingAuthorization
    include StoreModel::Model

    attribute :state, :string
    attribute :envelope, default: -> { {} }
    attribute :expires_at, :datetime
    attribute :owner_authority_generation, :integer

    validates :state, :expires_at, :owner_authority_generation, presence: true
  end

  attribute :redirect_uri, :string
  # These are the library's protocol envelopes, including its issuer binding.
  # Only the installation boundary interprets token response fields.
  attribute :client_information
  attribute :tokens
  attribute :expires_at, :datetime
  attribute :pending_authorization, PendingAuthorization.to_type
  attribute :operation, Operation.to_type
  attribute :reauthorization_reason, :string

  validates :operation, :pending_authorization, store_model: true, allow_nil: true
  validates :reauthorization_reason, inclusion: { in: %w[expired interrupted rejected authority_changed] }, allow_nil: true
  validate :bounded_document

  private

    def bounded_document
      errors.add(:base, :too_long, count: MAX_BYTES) if to_json.bytesize > MAX_BYTES
    end
end
