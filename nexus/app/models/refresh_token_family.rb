# The single durable authority owner for one OAuth refresh rotation family.
# Access and refresh rows are retained evidence; this row is the bounded
# family-wide fence that authentication and rotation consult.
class RefreshTokenFamily < ApplicationRecord
  # A connection lapses only by sitting unused — rotation with reuse detection
  # bounds a leaked lineage, not a calendar. A multiple of the token TTL so the
  # family always outlives a credential it minted.
  INACTIVITY_WINDOW = AccessToken::OAUTH_TTL * 2

  include Convergence
  include GuardedStamp

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  # A lineage is one signed-in program; the device facts are frozen at
  # consume like everything else about the connection.
  attr_readonly :account_id, :user_id, :public_id, :access_token_name,
    :task_executor_id, :credential_epoch, :user_authority_generation,
    :device_ip, :device_user_agent

  belongs_to :account
  # Absent for a runner lineage, whose credentials name only an address.
  belongs_to :user, optional: true
  # Every lineage is executor-bound; rotation_acceptable? dereferences
  # it unconditionally.
  belongs_to :task_executor
  has_many :access_tokens
  has_many :refresh_tokens

  validates :access_token_name,
    presence: true,
    length: { maximum: AccessToken::NAME_MAX_LENGTH }
  validates :credential_epoch, presence: true
  # The binding is creation-frozen; the unique index decides concurrent
  # issuers without adding this lookup to every rotation clock update.
  validates :credential_epoch,
    uniqueness: { scope: :task_executor_id },
    if: -> { task_executor_id.present? && credential_epoch.present? },
    on: :create
  validates :last_used_at, presence: true
  # The member authority snapshot exists only for a lineage that has a
  # member; a runner lineage names an address alone.
  validates :user_authority_generation, presence: true, if: :user_id?
  validates :user_authority_generation, absence: true, unless: :user_id?
  validate :owner_is_coherent
  validate :executor_binding_is_coherent

  # Live until explicitly revoked; natural lapse is reported per row. `live`
  # is not `usable`: the executor epoch advances before the family-marker
  # sweep, so rotation reads `rotation_acceptable?` and readiness `TaskExecutor.credential_readiness_for`.
  scope :live, -> { where(revoked_at: nil) }
  scope :order_by_recency, -> { order(created_at: :desc, id: :desc) }

  def revoked?
    revoked_at.present?
  end

  def within_lifetime?(now: Time.current)
    last_used_at > now - INACTIVITY_WINDOW
  end

  # The one side-effect-free rotation predicate: lapse stops rotation without
  # invalidating an unexpired token, and the address — not the member — is
  # the authority it reads. Member unavailability alone does not fence
  # transport; an executor epoch change, including Agent removal, does.
  def rotation_acceptable?(now: Time.current)
    !revoked? &&
      within_lifetime?(now: now) &&
      task_executor.transport_authorized_at?(credential_epoch)
  end

  # The family-wide revocation authority; per-row markers are converged
  # evidence. Ends the lineage and nothing else — the address belongs to the
  # profile, and only the steward's verb ends both.
  def revoke(now: Time.current) = stamp_if(self.class.where(revoked_at: nil), :revoked_at, at: now)

  private

    def owner_is_coherent
      return unless user

      errors.add(:user, :foreign_account) if user.account_id != account_id
      errors.add(:user, :not_agent_member) unless user.agent_member?
    end

    def executor_binding_is_coherent
      return if task_executor.nil?

      if task_executor.agent_profile_id != user_id || task_executor.account_id != account_id
        errors.add(:task_executor, :foreign_executor)
      end
    end
end
