# One piece of retained evidence in an OAuth refresh rotation family (RFC
# 9700). Mutable authorization facts live only on RefreshTokenFamily; this
# row records a presented secret and its successor.
class RefreshToken < ApplicationRecord
  DIGESTED = Nexus::DigestedSecret.new(
    prefix: "rt-cybros-api-v1",
    digest_salt: "cybros/refresh_token/refresh_digest"
  )

  # Consumed/revoked evidence remains recognizable for a fixed per-token
  # window: the family inactivity window plus the longest access-token
  # lifetime that the same rotation could have minted.
  EVIDENCE_RETENTION = RefreshTokenFamily::INACTIVITY_WINDOW + AccessToken::OAUTH_TTL
  # A current token still follows the original family-lapse ladder: collect it
  # one access-token lifetime after the family can no longer rotate.
  POST_LAPSE_RETENTION = AccessToken::OAUTH_TTL

  include Convergence

  # superseded_by_id is deliberately absent: it is rotation's state pointer
  # (nil -> successor, once), not an identity binding.
  attr_readonly :account_id, :user_id, :refresh_token_family_id, :access_token_id,
    :lookup_id, :secret_digest

  belongs_to :account
  belongs_to :user, optional: true
  belongs_to :refresh_token_family
  belongs_to :access_token, optional: true
  belongs_to :superseded_by, class_name: "RefreshToken", optional: true

  validates :lookup_id, :secret_digest, presence: true
  validate :family_anchors_are_coherent

  # Strict parse -> indexed lookup -> constant-time digest compare; a
  # malformed value never touches the database.
  def self.find_by_secret(raw)
    wire = DIGESTED.parse(raw)
    return nil unless wire

    token = includes(refresh_token_family: [:user, :task_executor])
      .find_by(lookup_id: wire.lookup_id)
    token if token && DIGESTED.digest_matches?(
      token.secret_digest,
      lookup_id: wire.lookup_id,
      secret: wire.secret
    )
  end

  def current?
    consumed_at.nil? && superseded_by_id.nil? && revoked_at.nil?
  end

  # Consumed/superseded but not yet marked revoked: presenting it is the RFC
  # 9700 reuse signal. The durable family fence may already be set.
  def replayable_evidence?
    revoked_at.nil? && (consumed_at.present? || superseded_by_id.present?)
  end

  private

    def family_anchors_are_coherent
      return unless refresh_token_family

      if refresh_token_family.account_id != account_id
        errors.add(:account, :family_mismatch)
      end
      if refresh_token_family.user_id != user_id
        errors.add(:user, :family_mismatch)
      end
      if access_token && access_token.refresh_token_family_id != refresh_token_family_id
        errors.add(:access_token, :family_mismatch)
      end
    end
end
