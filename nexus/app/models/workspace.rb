# THE OVERRIDE FACT: `tool_provider_overrides` is namespace-grained, one
# provider per kernel family, a public-id snapshot; read at the one
# addressing site, by the assembly block, by the conversation memory door and
# by the presenter — never by a provider (the row it receives carries the
# kernel's `scope` stamp instead).
class Workspace < ApplicationRecord
  include PublicIdentified
  NAME_MAX_LENGTH = 100

  LIVE_STATES = %w[active restoring].freeze
  BROWSABLE_STATES = %w[active archiving archived restoring].freeze
  TOMBSTONED_STATES = %w[deleting deleted].freeze

  include Access, Lifecycle, StoreHost

  # owner_id is deliberately absent: ownership transfer is the sanctioned
  # escape hatch.
  attr_readonly :account_id, :creator_id, :public_id, :agent_identifier

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :creator, class_name: "User"
  belongs_to :owner, class_name: "User"
  # Workspace-scope memory. Pointer rows cascade; the versions they name
  # are shared with whatever forked from a conversation here and are the
  # reclaim sweep's business, never this cascade's.
  has_many :memory_documents, dependent: :delete_all
  has_many :prompt_documents, dependent: :delete_all

  enum :access_mode, %w[account_wide private].index_by(&:itself),
    default: :private, validate: true, scopes: false
  enum :state, %w[active archiving archived restoring deleting deleted].index_by(&:itself),
    default: :active, validate: true, scopes: false

  # The visibility lattice, as composable relations.
  scope :live, -> { where(state: LIVE_STATES) }
  scope :browsable, -> { where(state: BROWSABLE_STATES) }
  scope :tombstoned, -> { where(state: TOMBSTONED_STATES) }
  scope :non_tombstoned, -> { where.not(state: TOMBSTONED_STATES) }

  validates :name, presence: true
  validates :name, length: { maximum: NAME_MAX_LENGTH }, allow_nil: true
  # The dedication tag mirrors the Profile identifier shape: exact,
  # case-sensitive, printable, create-frozen.
  validates :agent_identifier,
    length: { maximum: User::AGENT_IDENTIFIER_MAX_LENGTH },
    format: { with: /\A[[:print:]]+\z/ },
    allow_nil: true
  validate :owner_must_be_same_account_human
  validate :creator_must_be_same_account_principal
  validate :agent_identifier_must_be_the_creating_agents_own
  validate :agent_identifier_has_no_surrounding_whitespace
  validates :metadata, bounded_json: { bound: :workspace_metadata_bound, shape: Hash }
  validates :tool_provider_overrides, bounded_json: { bound: :tool_provider_overrides_bound, shape: Hash }
  # Checked only when the column changes: the value is a SNAPSHOT, so a
  # rename after the provider's reap does not re-judge a fact that was true
  # when written.
  validate :tool_provider_overrides_name_overridable_namespaces_and_live_providers,
    if: :will_save_change_to_tool_provider_overrides?

  def live?
    state.in?(LIVE_STATES)
  end

  def browsable?
    state.in?(BROWSABLE_STATES)
  end

  def tombstoned?
    state.in?(TOMBSTONED_STATES)
  end

  def non_tombstoned?
    !tombstoned?
  end

  # ── the provider override: two lock-free readers ─────────────

  # The provider PUBLIC ID a name's namespace is overridden to, or nil. A
  # reserved, source-routed (`skill`) or non-kernel name never consults
  # the map: the override branch is the only way a kernel name
  # leaves the kernel by a workspace's choice, and only an overridable one
  # may (`Nexus::ToolRegistry.overridable?`, the one classifier).
  def tool_provider_override_for(name)
    return nil unless Nexus::ToolRegistry.overridable?(name)

    tool_provider_overrides[Nexus::ToolRegistry.namespace(Nexus::ToolRegistry.resolve(name))]
  end

  # The provider ROW, or nil — NOT filtered by status: addressing refuses a
  # revoked one through `eligible_for?` with the honest detail, and the
  # presenter names it so a person sees why.
  def tool_provider_for(name)
    public_id = tool_provider_override_for(name)
    return nil if public_id.nil?

    TaskExecutor.find_by(account_id: account_id, public_id: public_id, executor_kind: :tool_provider)
  end

  # ── the write ladder, and StoreHost's answers ──────────

  # Data writes, not management: no access conceals the Workspace exactly
  # like absence, in concealment-first order. The fence stays at its one
  # site (Access) and is reached from here for the conversation host and
  # the override writer alike.
  def write_refusal(user)
    if tombstoned? || !data_accessible_by?(user)
      :not_found
    elsif dedication_fenced_against?(user)
      :workspace_agent_identifier_mismatch
    elsif !live?
      :workspace_not_active
    end
  end

  # The StoreHost contract's name for the same ladder — two names, one body.
  def store_write_refusal(user) = write_refusal(user)

  # The Workspace row lock serializes concurrent creates so the bounded
  # count cannot admit a 65th entry; distinct-key inserts at 63 produce one
  # 64th row and one stable limit loser. Workspace → writer → steward, the
  # ladder's order (workspaces above users).
  def with_store_create_lock(writer)
    with_lock { yield lock_writer(writer) }
  end

  # The workspace's receipts as today: `workspace_command_receipts` under
  # its `store_entry_create` partial index.
  def store_create_receipts(acting_user:, idempotency_key:, request_digest:)
    WorkspaceCommandReceipt::Idempotent.new(
      account: account, acting_user: acting_user, workspace: self,
      operation: :store_entry_create,
      idempotency_key: idempotency_key, request_digest: request_digest
    )
  end

  def store_receipt_success(status:, body:)
    WorkspaceCommandReceipt::Idempotent::Success.new(status: status, body: body, workspace: self)
  end

  private

    # Active status is an assignment-time service rule, not validated here: a
    # later owner suspension must not invalidate the row's unrelated saves.
    def owner_must_be_same_account_human
      if owner && !(owner.human? && owner.account_id == account_id)
        errors.add(:owner, :not_eligible)
      end
    end

    def creator_must_be_same_account_principal
      if creator && !((creator.human? || creator.agent_member?) && creator.account_id == account_id)
        errors.add(:creator, :not_eligible)
      end
    end

    # Agent-created Workspaces always carry the creator's identifier; every
    # other creator shape carries none.
    def agent_identifier_must_be_the_creating_agents_own
      if creator&.agent_member?
        if agent_identifier != creator.agent_identifier
          errors.add(:agent_identifier, :not_allowed)
        end
      elsif agent_identifier
        errors.add(:agent_identifier, :not_allowed)
      end
    end

    def agent_identifier_has_no_surrounding_whitespace
      if agent_identifier && agent_identifier != agent_identifier.strip
        errors.add(:agent_identifier, :invalid)
      end
    end

    # Every key an overridable LIVE namespace, every value naming a live
    # tools provider of this account. The shape validator judged a
    # non-object already; a value that is not a public id is a miss.
    def tool_provider_overrides_name_overridable_namespaces_and_live_providers
      Hash.try_convert(tool_provider_overrides).to_h.each do |namespace, provider_public_id|
        unless Nexus::ToolRegistry.overridable_namespaces.include?(namespace)
          errors.add(:tool_provider_overrides, :namespace_not_overridable, namespace: namespace)
          next
        end
        unless live_tool_provider?(provider_public_id.to_s)
          errors.add(:tool_provider_overrides, :provider_unknown, provider: provider_public_id.to_s.first(64))
        end
      end
    end

    def live_tool_provider?(public_id)
      TaskExecutor.live.exists?(account_id: account_id, executor_kind: :tool_provider, public_id: public_id)
    end
end
