class SsoConnection < ApplicationRecord
  belongs_to :identity
  belongs_to :sso_provider, inverse_of: :sso_connections

  attr_readonly :identity_id, :sso_provider_id, :subject
  validates :subject, presence: true, length: { maximum: 512 }
  validates :display_name, length: { maximum: 255 }
  validate :same_account

  scope :available, -> {
    joins(:sso_provider).where(sso_providers: { enabled: true })
      .where("sso_connections.admission_version = sso_providers.admission_version")
  }

  def removable?(policy: sso_provider.account)
    !SsoProvider.uncovered_users(policy, sso_only: policy.sso_only?, except_provider: sso_provider)
      .where(identity_id: identity_id).exists?
  end

  def disconnect
    policy = identity.account
    policy.with_lock do
      if removable?(policy: policy)
        destroy!
        true
      else
        errors.add(:base, :last_login_method)
        false
      end
    end
  end

  private

    def same_account
      if identity && sso_provider && identity.account_id != sso_provider.account_id
        errors.add(:identity, :invalid)
      end
    end
end
