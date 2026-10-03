# The durable delivery address: an agent_application address is bound to its
# Agent Profile; a MACHINE — a runner, or a tools provider — is managed by
# one human under a logical registration key. All are single-instance,
# outlive any credential lineage, and are fenced by the monotone epoch.
class TaskExecutor < ApplicationRecord
  include PublicIdentified
  include GuardedStamp
  DISPLAY_NAME_MAX_LENGTH = 100
  # The two kinds with the machine ownership shape: a manager Human, an
  # identifier, a scope. A tools provider is registered the way a runner is
  # and differs only in what it claims — pool rows, never a binding.
  MACHINE_KINDS = %w[runner tools_provider].freeze
  # Last activity beside presence: sampled once a minute, so "offline (last
  # seen 3m ago)" is not an hour stale — one WHERE-guarded UPDATE per
  # executor per minute against the sweep's twelve reads. NOT
  # AccessToken::LAST_USED_REFRESH_RATE and never shared with it: the two
  # stamps answer different questions and must be free to diverge without one
  # silently retuning the other; the inactivity gate stays on `last_used_at`.
  LAST_SEEN_REFRESH_RATE = 1.minute
  RUNNER_IDENTIFIER_MAX_LENGTH = 128
  ShutdownPending = Class.new(StandardError)

  include Convergence
  include CredentialReadiness
  include Announcement
  include Addressing
  include Presence

  attr_readonly :account_id, :agent_profile_id, :public_id, :executor_kind,
    :runner_identifier, :manager_id, :assignment_scope

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  # An agent_application belongs to its Agent Profile. Every runner has one
  # human manager regardless of whether its assignment ACL is private or
  # account-wide.
  belongs_to :agent_profile, class_name: "User", optional: true
  belongs_to :manager, class_name: "User", optional: true
  has_many :access_tokens
  has_many :refresh_token_families

  enum :executor_kind, %w[agent_application runner tools_provider].index_by(&:itself),
    validate: true, scopes: false
  enum :status, %w[active revoked].index_by(&:itself), default: :active, validate: true, scopes: false
  enum :assignment_scope, %w[user_private account_wide].index_by(&:itself),
    validate: { allow_nil: true }, scopes: false

  before_validation :freeze_initial_human_shutdown_generation, on: :create

  validates :display_name, presence: true, length: { maximum: DISPLAY_NAME_MAX_LENGTH }
  validates :runner_identifier, length: { maximum: RUNNER_IDENTIFIER_MAX_LENGTH }, allow_nil: true
  validates :agent_profile_id,
    uniqueness: {
      conditions: -> {
        where(executor_kind: :agent_application).where.not(status: :revoked)
      },
    },
    if: -> { agent_application? && !revoked? && agent_profile_id.present? },
    on: :create
  # The live-identity index's own predicate: one live address per
  # (account, manager, identifier) key across BOTH machine kinds.
  validates :runner_identifier,
    uniqueness: {
      scope: %i[account_id manager_id],
      conditions: -> {
        where(executor_kind: MACHINE_KINDS).where.not(status: :revoked)
      },
    },
    if: -> {
      machine? && !revoked? && manager_id.present? && runner_identifier.present? &&
        runner_identity_key_changed?
    }
  # Each kind has exactly one shape of ownership.
  with_options if: :agent_application? do
    validates :agent_profile, presence: true
    validates :manager, :assignment_scope, :runner_identifier, absence: true
  end
  with_options unless: :agent_application? do
    validates :agent_profile, absence: true
    validates :runner_identifier, :assignment_scope, :manager, presence: true
  end
  validate :agent_profile_must_be_agent_member
  validate :agent_profile_must_be_eligible, on: :create
  validate :runner_manager_must_be_eligible

  scope :live, -> { where.not(status: :revoked) }
  scope :order_by_recency, -> { order(created_at: :desc, id: :desc) }

  # A winning replacement keeps the address while moving its credential
  # authority forward; the model owns the transition.
  def re_pair(display_name:)
    with_lock do
      raise ArgumentError, "a revoked TaskExecutor cannot be re-paired" if revoked?
      unless connection_authority_open?
        raise ShutdownPending, "connection authority is closed by the controlling Human"
      end

      update!(
        credential_epoch: credential_epoch + 1,
        display_name: display_name,
        last_seen_at: nil,
        presence_connection_id: nil,
        presence_server_id: nil,
        connected_at: nil
      )
    end
    self
  end

  # Cut transport authority synchronously. The bounded park sweep settles
  # unclaimed work as executor_revoked; its recurring run also recovers a
  # lost wake. Claimed work keeps its deadline and effect-profile settlement.
  def revoke
    with_lock do
      unless revoked?
        update!(status: :revoked, presence_connection_id: nil, presence_server_id: nil, connected_at: nil)
      end
    end
    self.class.current_transaction.after_commit do
      AgentLoops::Parks::TimeoutSweepJob.perform_later
    end
    :revoked
  end

  # "Stop this machine now": the epoch advance is the O(1) fence,
  # convergence marks the families later; a terminal address stays stable
  # as a pairing marker, so a repeat is a no-op.
  def revoke_credentials
    with_lock do
      update!(
        credential_epoch: credential_epoch + 1,
        last_seen_at: nil,
        presence_connection_id: nil,
        presence_server_id: nil,
        connected_at: nil
      ) unless revoked?
    end
    :revoked
  end

  # Level-triggered by a durable generation mismatch, not the Human's status,
  # so restore cannot erase an unfinished shutdown episode. The the epoch
  # advances only when no non-terminal row is claimed by this executor and
  # its unclaimed addressed work is cleared — `:work_pending` otherwise, and
  # the next wake retries — so the credential that took a call can still
  # answer it.
  def converge_human_shutdown(
    expected_human_id:,
    expected_generation:,
    expected_applied_generation:
  )
    self.class.transaction do
      locked_profile = User.lock.find_by(id: agent_profile_id) if agent_application?
      human_id = machine? ? manager_id : locked_profile&.steward_id
      return :control_changed unless human_id == expected_human_id

      with_lock do
        current_human_id = machine? ? manager_id : locked_profile&.steward_id
        if current_human_id != expected_human_id
          :control_changed
        elsif applied_human_shutdown_generation != expected_applied_generation
          :stale
        elsif applied_human_shutdown_generation == expected_generation
          :already_converged
        elsif holds_addressed_work? || holds_claimed_work?
          :work_pending
        else
          update!(
            credential_epoch: credential_epoch + 1,
            applied_human_shutdown_generation: expected_generation,
            last_seen_at: nil,
            presence_connection_id: nil,
            presence_server_id: nil,
            connected_at: nil
          )
          :converged
        end
      end
    end
  end

  # THE UPLOAD ANCHOR: a CAPTURE this executor publishes is staged as its
  # own — the executor plane's twin of `User#content_upload_anchor`. Set at
  # `create!` alone (`attr_readonly`).
  def content_upload_anchor = { creating_executor: self }

  # The shared executor-transport predicate: explicit lifecycle plus the
  # presented epoch snapshot. User operability is checked by task
  # publication/start, not by the transport address.
  def transport_authorized_at?(epoch)
    !revoked? && credential_epoch == epoch
  end

  private

    def runner_identity_key_changed?
      new_record? || will_save_change_to_manager_id?
    end

    # Liveness is checked when management is assigned. A later Human lifecycle
    # transition gates connection authority dynamically and converges shutdown;
    # it does not make unrelated Runner saves invalid.
    def runner_manager_must_be_eligible
      if machine? && will_save_change_to_manager_id? && manager &&
          !manager.active_human_member?
        errors.add(:manager, :not_eligible)
      elsif machine? && will_save_change_to_manager_id? && manager &&
          manager.account_id != account_id
        errors.add(:manager, :not_eligible)
      end
    end

    def agent_profile_must_be_agent_member
      if agent_profile && !agent_profile.agent_member?
        errors.add(:agent_profile, :not_agent_member)
      end
    end

    # Final current-state acceptance at every creation path: the acting
    # agent and its steward must be active, in this account.
    def agent_profile_must_be_eligible
      if agent_profile &&
          (!agent_profile.execution_principal_eligible? ||
            agent_profile.account_id != account_id)
        errors.add(:agent_profile, :not_eligible)
      end
    end
end
