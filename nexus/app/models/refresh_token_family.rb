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
    :device_ip, :device_user_agent, :identity_recovery_generation, :client_id,
    :bound_agent_id, :bound_runner_id

  belongs_to :account
  # Absent for a runner lineage, whose credentials name only an address.
  belongs_to :user, optional: true
  # Human application login has no executor binding.
  belongs_to :task_executor, optional: true
  belongs_to :bound_agent, class_name: "User", optional: true
  belongs_to :bound_runner, class_name: "TaskExecutor", optional: true
  has_many :access_tokens
  has_many :refresh_tokens

  validates :access_token_name,
    presence: true,
    length: { maximum: AccessToken::NAME_MAX_LENGTH }
  validates :client_id, inclusion: { in: [OAuth::DEVICE_CLIENT_ID, OAuth::APPLICATION_CLIENT_ID] }
  validates :credential_epoch, presence: true, if: :task_executor_id?
  validates :credential_epoch, absence: true, unless: :task_executor_id?
  validates :identity_recovery_generation, presence: true, if: :human_connection?
  validates :identity_recovery_generation, absence: true, unless: :human_connection?
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
  validate :application_binding_is_coherent

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
  # invalidating an unexpired token. A Human lineage follows current Human
  # authority and application binding; a transport lineage follows its address.
  # Member unavailability alone does not fence transport.
  def rotation_acceptable?(now: Time.current)
    !revoked? &&
      within_lifetime?(now: now) &&
      (human_connection? ? human_authority_live?(user) : task_executor.transport_authorized_at?(credential_epoch))
  end

  def human_connection?
    task_executor_id.nil? && user_id.present?
  end

  def human_authority_live?(member)
    member&.active_human_member? &&
      user_authority_generation == member.authority_generation &&
      identity_recovery_generation == member.identity.credential_recovery_generation &&
      !member.identity.local_recovery_pending? && !member.identity.password_change_required? &&
      application_binding_live?(member)
  end

  def application_binding_live?(member)
    if bound_agent_id
      bound_agent.active? && bound_agent.steward_id == member.id && bound_agent.steward_live?
    elsif bound_runner_id
      bound_runner.active? && bound_runner.manager_id == member.id && bound_runner.connection_authority_open?
    else
      false
    end
  end

  # The family-wide revocation authority; per-row markers are converged
  # evidence. Ends the lineage and nothing else — the address belongs to the
  # profile, and only the steward's verb ends both.
  def revoke(now: Time.current) = stamp_if(self.class.where(revoked_at: nil), :revoked_at, at: now)

  private

    def owner_is_coherent
      return unless user

      errors.add(:user, :foreign_account) if user.account_id != account_id
      if human_connection?
        errors.add(:user, :not_human) unless user.human?
      else
        errors.add(:user, :not_agent_member) unless user.agent_member?
      end
    end

    def application_binding_is_coherent
      if human_connection?
        valid_binding = bound_agent_id.present? ^ bound_runner_id.present?
        errors.add(:bound_agent, :incomplete_binding) unless valid_binding
        if bound_agent && (bound_agent.account_id != account_id || bound_agent.steward_id != user_id || !bound_agent.agent_member?)
          errors.add(:bound_agent, :foreign_account)
        end
        if bound_runner && (bound_runner.account_id != account_id || bound_runner.manager_id != user_id || bound_runner.agent_application?)
          errors.add(:bound_runner, :foreign_account)
        end
        errors.add(:client_id, :invalid) unless client_id == OAuth::APPLICATION_CLIENT_ID
      elsif bound_agent_id || bound_runner_id
        errors.add(:bound_agent, :present)
      end
    end

    def executor_binding_is_coherent
      if task_executor.nil?
        errors.add(:task_executor, :blank) unless user&.human?
        return
      end

      if task_executor.agent_id != user_id || task_executor.account_id != account_id
        errors.add(:task_executor, :foreign_executor)
      end
    end
end
