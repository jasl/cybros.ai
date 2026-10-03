# Encrypted per-lane provider credential, one row per (Account, lane). Active Record encryption is the
# protection, no serializer filter; a Codex pair comes from the device flow or a rotation. A manual
# development tool may seed the same credential through the ordinary install command.
class ModelProviderCredential < ApplicationRecord
  MATERIAL_KINDS = %w[api_key oauth_tokens].freeze
  # Release-fixed five-minute authorization clock skew.
  OAUTH_CLOCK_SKEW_SECONDS = 300

  belongs_to :account
  attr_readonly :account_id, :provider_id, :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  encrypts :secret
  encrypts :refresh_secret
  encrypts :provider_account_identity

  validates :provider_id, presence: true, length: { maximum: 64 }
  validates :material_kind, inclusion: { in: MATERIAL_KINDS }
  validates :secret, presence: true
  validate :material_kind_shape

  # One more execution deadline ahead of the usable horizon, leaving room
  # for the refresh and one replaced failure; a multiple, so a lane
  # allowing longer calls gets a longer lead.
  REFRESH_LEAD_DEADLINES = 2

  # The provider's pairs a refresh should start for before they stop being usable:
  # an enabled lane, a pair not marked for a human, soonest expiry first, and
  # `usable_for?` asked further out so the horizon arithmetic lives in one place.
  # The unit is the workload backstop: a token left alone must still cover the
  # longest text call twice over.
  def self.refresh_due(provider_id:, limit:, now:)
    lead = SimpleInference::ApiFormat.deadline_seconds("text_generation") * REFRESH_LEAD_DEADLINES
    joins(<<~SQL.squish)
      INNER JOIN model_provider_policies
        ON model_provider_policies.account_id = model_provider_credentials.account_id
       AND model_provider_policies.provider_id = model_provider_credentials.provider_id
    SQL
      .where(
        provider_id: provider_id,
        material_kind: "oauth_tokens",
        reauthorization_required: false,
        model_provider_policies: { enabled: true }
      )
      .where.not(refresh_secret: nil)
      .order(:expires_at)
      .limit(limit)
      .reject { |credential| credential.usable_for?(total_execution_deadline_seconds: lead, now: now) }
  end

  # The one usability question every read/start gate asks. Strictly greater:
  # equality at the horizon is unusable.
  def usable_for?(total_execution_deadline_seconds:, now:)
    return false if reauthorization_required?
    return true if expires_at.nil? && material_kind == "api_key"
    return false if expires_at.nil?

    expires_at > now + total_execution_deadline_seconds + OAUTH_CLOCK_SKEW_SECONDS
  end

  private

  def material_kind_shape
    case material_kind
    when "api_key"
      errors.add(:refresh_secret, :oauth_only) if refresh_secret.present?
      errors.add(:authorization_lineage_id, :oauth_only) if authorization_lineage_id.present?
    when "oauth_tokens"
      errors.add(:refresh_secret, :pair_incomplete) if refresh_secret.blank?
      errors.add(:authorization_lineage_id, :unminted) if authorization_lineage_id.blank?
      errors.add(:expires_at, :pair_requires_expiry) if expires_at.nil?
    else
      # The closed-vocabulary inclusion validation already rejected it.
      nil
    end
  end
end
