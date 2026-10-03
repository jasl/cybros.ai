# One RFC 8628 connection transaction: the device code is the machine secret,
# the user code is the human handle, and a signed-in human connects it to the
# automatically resolved Agent profile before consume can mint.
class DeviceAuthorization < ApplicationRecord
  include PublicIdentified
  DIGESTED = Nexus::DigestedSecret.new(
    prefix: "dc-cybros-v1",
    digest_salt: "cybros/device_authorization/device_code_digest"
  )

  # Base-20 charset without vowels or ambiguous glyphs.
  USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ".freeze
  USER_CODE_LENGTH = 8
  TTL = 15.minutes
  DEFAULT_INTERVAL = 5
  SLOW_DOWN_STEP = 5
  MAX_INTERVAL = 60
  EXPOSURE_BUDGET = 5
  TERMINAL_RETENTION = 7.days
  # The two states a transaction is still decidable/redeemable from; every
  # other status is terminal.
  LIVE_STATUSES = %w[pending connected].freeze

  include Convergence

  attr_readonly :account_id, :public_id, :client_id, :agent_identifier, :agent_display_name,
    :requested_executor_display_name,
    :runner_identifier, :runner_display_name, :requested_executor_kind,
    :device_code_lookup_id, :device_code_digest, :user_code, :expires_at

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :user, optional: true
  belongs_to :connected_by, class_name: "User", optional: true
  belongs_to :task_executor, optional: true
  belongs_to :access_token, optional: true
  belongs_to :refresh_token, optional: true
  has_many :device_grant_verifications, dependent: :delete_all

  enum :status, %w[pending connected canceled expired consumed invalidated].index_by(&:itself),
    default: :pending, validate: true, scopes: false

  # A Runner machine does not choose its placement. The browser Connect
  # transition freezes this human-selected consequence; pending requests and
  # every Agent request carry nil.
  enum :selected_assignment_scope, %w[user_private account_wide].index_by(&:itself),
    validate: { allow_nil: true }, scopes: false, prefix: :selects

  validates :client_id, inclusion: { in: [OAuth::DEVICE_CLIENT_ID] }
  validates :agent_identifier, length: { maximum: User::AGENT_IDENTIFIER_MAX_LENGTH }, allow_nil: true
  validates :agent_display_name, length: { maximum: User::DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
  validates :runner_identifier,
    length: { maximum: TaskExecutor::RUNNER_IDENTIFIER_MAX_LENGTH }, allow_nil: true
  validates :runner_display_name,
    length: { maximum: TaskExecutor::DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
  validates :requested_executor_display_name,
    presence: true, length: { maximum: TaskExecutor::DISPLAY_NAME_MAX_LENGTH },
    unless: :runner_only_connection?
  validates :requested_executor_display_name, absence: true, if: :runner_only_connection?
  validates :interval, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :expected_task_executor_status,
    inclusion: { in: TaskExecutor.statuses.keys }, allow_nil: true
  # Every shape but B names its agent; a row naming neither identifier is
  # not a shape at all.
  validates :agent_identifier, :agent_display_name, presence: true, unless: :runner_only_connection?
  # Branch B names the machine kind it wants, frozen at issuance like the
  # identifier; an Agent connection's kind is the branch's own.
  with_options if: :runner_only_connection? do
    validates :runner_display_name, presence: true
    validates :requested_executor_kind, inclusion: { in: TaskExecutor::MACHINE_KINDS }
    validates :agent_identifier, :agent_display_name, :requested_executor_display_name, absence: true
  end
  with_options if: :agent_connection? do
    validates :runner_display_name, :selected_assignment_scope, :requested_executor_kind, absence: true
  end
  # The combined shape: both claim sets complete, the kind fixed `runner` (a
  # tools provider under an agent's grant is meaningless) and the scope fixed
  # `user_private` at Issue in EVERY status — the in-process runner is always
  # private; shared capacity is a runner-mode registration.
  with_options if: :combined_connection? do
    validates :runner_display_name, presence: true
    validates :requested_executor_kind, inclusion: { in: %w[runner] }
    validates :selected_assignment_scope, inclusion: { in: %w[user_private] }
  end
  # A runner's placement is frozen by Connect and kept through consumption;
  # before that, and after a cancel, there is none to hold.
  validates :selected_assignment_scope, presence: true,
    if: [:runner_only_connection?, -> { connected? || consumed? || invalidated? }]
  validates :selected_assignment_scope, absence: true,
    if: [:runner_only_connection?, -> { pending? || canceled? }]
  validate :pairing_precondition_is_complete
  validate :connector_precondition_is_complete
  validate :selected_assignment_scope_changes_only_with_connection

  # A request declares one of three shapes: A (agent), B (machine), A+B
  # (the combined grant of an agent that also serves as a runner on its
  # own machine — rho in full mode). Combined = both claim sets complete;
  # anything between is invalid_request on the wire. Branch B is a MACHINE
  # connection — a runner or a tools provider, by
  # `requested_executor_kind` — with the runner's ceremony either way; the
  # combined shape takes the AGENT's ceremony, its runner half riding the
  # agent triple's fence (the recorded asymmetry).
  def runner_only_connection?
    runner_identifier.present? && agent_identifier.blank?
  end

  def agent_connection?
    agent_identifier.present? && runner_identifier.blank?
  end

  def combined_connection?
    agent_identifier.present? && runner_identifier.present?
  end

  def tools_provider_connection?
    runner_only_connection? && requested_executor_kind == "tools_provider"
  end

  # A live Runner marker means Connect is re-pairing an existing
  # registration. Its immutable ACL is therefore already decided; an absence
  # or terminal marker is a genuinely new registration. The combined grant's
  # runner half re-pairs by Consume's own finder, never by the row's marker.
  def reconnecting_live_runner?
    runner_only_connection? &&
      expected_task_executor_public_id.present? &&
      expected_task_executor_status != "revoked"
  end

  # Connect freezes the selected address identity and epoch without touching
  # the address; a retained terminal marker versions an absence, all nil means
  # no row remains. The frozen marker cannot be reaped until this resolves.
  def record_connection(user:, connector:, expected_task_executor:, selected_assignment_scope: nil)
    raise ArgumentError, "only a pending device authorization can connect" unless pending?

    update!(
      status: :connected,
      user: user,
      connected_by: connector,
      connected_by_authority_generation: connector.authority_generation,
      selected_assignment_scope: selected_assignment_scope,
      user_authority_generation: user&.authority_generation,
      expected_task_executor_public_id: expected_task_executor&.public_id,
      expected_credential_epoch: expected_task_executor&.credential_epoch,
      expected_task_executor_status: expected_task_executor&.status
    )
  end

  # Browser cancellation owns no durable membership or credential consequence.
  # Clear the frozen CAS tuple together with the terminal transition so a
  # canceled row cannot retain a false address dependency. A combined row's
  # scope was fixed at Issue and is never cleared.
  def record_cancellation
    unless pending? || connected?
      raise ArgumentError, "only a live device authorization can be canceled"
    end

    update!(
      status: :canceled,
      connected_by: nil,
      connected_by_authority_generation: nil,
      user: nil,
      selected_assignment_scope: (selected_assignment_scope if combined_connection?),
      user_authority_generation: nil,
      expected_task_executor_public_id: nil,
      expected_credential_epoch: nil,
      expected_task_executor_status: nil
    )
  end

  # A winning Consume writes its terminal evidence pointers as one model
  # transition. Credential creation remains in the application service because
  # it spans the User, address, lineage, and token aggregates.
  def record_consumption(user: nil, task_executor:, access_token:, refresh_token:)
    raise ArgumentError, "only a connected device authorization can be consumed" unless connected?

    update!(
      status: :consumed,
      user: user,
      task_executor: task_executor,
      access_token: access_token,
      refresh_token: refresh_token
    )
  end

  # Consume calls this after taking the rows that own pairing order. A
  # replacement address may begin at the same epoch as the revoked address,
  # so both immutable public identity and epoch must still match.
  def pairing_matches?(task_executor)
    if expected_task_executor_public_id
      task_executor&.public_id == expected_task_executor_public_id &&
        task_executor.credential_epoch == expected_credential_epoch &&
        task_executor.status == expected_task_executor_status
    else
      task_executor.nil?
    end
  end

  scope :live, -> { where(status: LIVE_STATUSES) }

  private

    # This field cannot use attr_readonly because Connect writes it after
    # issuance. Instead, admit exactly the two model-owned transitions:
    # pending nil -> connected value, and connected value -> canceled nil.
    def selected_assignment_scope_changes_only_with_connection
      return unless persisted? && will_save_change_to_selected_assignment_scope?

      scope_change = selected_assignment_scope_change_to_be_saved
      status_change = status_change_to_be_saved
      connecting =
        scope_change.first.nil? &&
        scope_change.last.in?(self.class.selected_assignment_scopes.keys) &&
        status_change == %w[pending connected]
      canceling =
        scope_change.first.in?(self.class.selected_assignment_scopes.keys) &&
        scope_change.last.nil? &&
        status_change == %w[connected canceled]
      errors.add(:selected_assignment_scope, :readonly) unless connecting || canceling
    end

    def pairing_precondition_is_complete
      pairing_values = [
        expected_task_executor_public_id,
        expected_credential_epoch,
        expected_task_executor_status,
      ]
      if pairing_values.any?(&:present?) && !pairing_values.all?(&:present?)
        errors.add(:expected_task_executor_public_id, :incomplete)
        errors.add(:expected_credential_epoch, :incomplete)
        errors.add(:expected_task_executor_status, :incomplete)
      end
    end

    def connector_precondition_is_complete
      connector_values = [
        connected_by_id,
        connected_by_authority_generation,
      ]
      any = connector_values.any?(&:present?)
      all = connector_values.all?(&:present?)
      valid_shape = case status
      when "connected", "consumed", "invalidated"
        all
      when "pending", "canceled"
        !any
      when "expired"
        !any || all
      else
        false
      end
      return if valid_shape

      errors.add(:connected_by, :incomplete)
      errors.add(:connected_by_authority_generation, :incomplete)
    end

  public

  class << self
    # The interval a device flow publishes and a row is issued with:
    # DEFAULT_INTERVAL unless the deployment sets NEXUS_DEVICE_FLOW_INTERVAL
    # (a test harness polls faster), never below what the row validates.
    def default_interval
      [Integer(ENV.fetch("NEXUS_DEVICE_FLOW_INTERVAL", DEFAULT_INTERVAL)), 1].max
    end

    # Strict parse -> indexed lookup -> constant-time digest compare; a
    # malformed value never touches the database.
    def find_by_device_code(raw)
      wire = DIGESTED.parse(raw)
      return nil unless wire

      authorization = find_by(device_code_lookup_id: wire.lookup_id)
      if authorization &&
          DIGESTED.digest_matches?(authorization.device_code_digest, lookup_id: wire.lookup_id, secret: wire.secret)
        authorization
      end
    end

    # Case-insensitive entry accepting the display hyphen and ordinary
    # spaces as visual separators.
    def normalize_user_code(input)
      input.to_s.upcase.gsub(/[\s-]/, "")
    end

    def find_live_by_user_code(input)
      normalized = normalize_user_code(input)
      return nil unless normalized.match?(/\A[#{USER_CODE_ALPHABET}]{#{USER_CODE_LENGTH}}\z/o)

      live.find_by(user_code: normalized)
    end

    # Consume invokes this while holding the authorization lock in its mint
    # transaction, so the drift decision and terminal marker commit
    # atomically. The guard keeps the transition monotone for other callers.
    def invalidate_connected(id)
      where(id: id, status: "connected").update_all(status: "invalidated", updated_at: Time.current)
    end
  end

  def formatted_user_code
    "#{user_code[0, 4]}-#{user_code[4, 4]}"
  end

  def live?
    status.in?(LIVE_STATUSES)
  end

  # The per-code exposure budget: DeviceGrantVerification owns distinct-context
  # idempotence under this row's lock, then calls this guarded increment. At
  # the budget the code stops resolving.
  def charge_exposure
    charged = self.class.where(id: id, status: LIVE_STATUSES)
      .where(exposure_count: ...EXPOSURE_BUDGET)
      .update_all(["exposure_count = exposure_count + 1, updated_at = ?", Time.current])
    reload
    charged.positive?
  end


  # Clock expiry is materialized lazily by whoever observes it (the sweep
  # also converges it): a guarded transition from either live state.
  def materialize_expiry
    if self.class.where(id: id, status: LIVE_STATUSES).where(expires_at: ..Time.current)
        .update_all(status: "expired", updated_at: Time.current).positive?
      reload
    end
    self
  end
end
