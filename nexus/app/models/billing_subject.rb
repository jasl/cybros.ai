# A minimal opaque grouping identity: no status, balance, limit, payer or cost
# unit, never a third cost-control layer. UsageRecord snapshots its key with
# no live FK.
class BillingSubject < ApplicationRecord
  # The one normalization, shared by the digesting envelope and the storing writer.
  # Absent, null and blank all normalize to nil; the key stays opaque.
  def self.normalize_key(value)
    key = value.to_s.strip
    key.presence
  end

  def self.key_within_bounds?(key)
    key.nil? || key.length <= KEY_MAX_LENGTH
  end

  KEY_MAX_LENGTH = 128

  attr_readonly :account_id, :owning_user_id, :public_id, :key

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :owning_user, class_name: "User"

  validates :key, presence: true, length: { maximum: KEY_MAX_LENGTH }
  validate :owner_shares_the_account

  private

    def owner_shares_the_account
      return if owning_user.nil? || account.nil?
      return if owning_user.account_id == account_id

      errors.add(:owning_user, :other_account)
    end
end
