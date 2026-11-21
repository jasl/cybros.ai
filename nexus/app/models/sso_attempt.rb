class SsoAttempt < ApplicationRecord
  include PublicIdentified

  LIFETIME = 10.minutes
  PURPOSES = %w[login connect invitation test reauth recovery].freeze

  belongs_to :sso_provider
  belongs_to :account, default: -> { sso_provider.account }
  belongs_to :session, optional: true
  belongs_to :member_recovery_authorization, optional: true
  encrypts :code_verifier
  attr_readonly :account_id, :sso_provider_id, :session_id, :public_id, :purpose,
    :state_digest, :browser_digest, :provider_version, :invitation_public_id,
    :member_recovery_authorization_id, :redirect_uri, :return_path, :action_name, :action_target

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }
  attribute :phase, default: "pending"
  validates :purpose, inclusion: { in: PURPOSES }
  validates :phase, inclusion: { in: %w[pending exchanging confirming proved] }

  scope :unexpired, -> { where(expires_at: Time.current..) }

  def self.digest(value) = Digest::SHA256.hexdigest(value)

  def self.reap_expired(batch_size: 500)
    where(expires_at: ..Time.current).order(:expires_at, :id).limit(batch_size).delete_all
  end

  def config_for_exchange
    purpose == "test" ? sso_provider.test_candidate : sso_provider
  end

  def claim_exchange
    self.class.unexpired.where(id: id, phase: "pending").update_all(phase: "exchanging") == 1
  end

  def store_profile(profile)
    update!(phase: "confirming", code_verifier: nil, subject: profile.subject,
      display_name: profile.name, email: profile.email, email_verified: profile.email_verified)
  end

  def grant_proof
    update!(phase: "proved", expires_at: 5.minutes.from_now)
  end
end
