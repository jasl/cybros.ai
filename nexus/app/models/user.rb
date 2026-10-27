class User < ApplicationRecord
  include PublicIdentified
  DISPLAY_NAME_MAX_LENGTH = 100
  SYSTEM_DISPLAY_NAME = "System".freeze
  AGENT_IDENTIFIER_MAX_LENGTH = 128

  include Role, Lifecycle, Connections, Convergence, Configurable, StoreHost, Handle, NamedAgent
  # A member hosts its own narration rows: `handle_changed` lands here, on
  # the renamed member, never on a conversation or a loop.
  include EventHost

  # steward_id is deliberately absent: reassignment is the one sanctioned
  # escape hatch, conceptually snapshot -> delete -> recreate.
  attr_readonly :account_id, :identity_id, :kind, :public_id, :agent_identifier

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :identity, optional: true
  belongs_to :steward, class_name: "User", optional: true
  has_many :sessions, dependent: :destroy
  has_many :access_tokens, dependent: :destroy
  has_many :api_keys, -> { where(source: :api_key, credential_plane: :member) }, class_name: "AccessToken"
  has_many :executor_api_keys, -> { where(source: :api_key, credential_plane: :executor_transport) }, class_name: "AccessToken"
  has_many :refresh_tokens, dependent: :destroy
  has_many :refresh_token_families, dependent: :destroy
  # Budget ownership: the FK is required, and budgets leave only with the
  # Account's own cascade, which is declared ahead of `has_many :users`.
  has_many :usage_budgets
  # Reversible member removal keeps collections. Physical destruction waits
  # for the owning cleanup to drain their documents and identity rows.
  # The FK refuses an incomplete drain.
  has_many :memory_collections
  has_many :memory_documents, through: :memory_collections
  has_many :prompt_documents, dependent: :delete_all
  # The profile store rides the same cascade for the same reason: a removed
  # User keeps its rows, erase takes them when it lands. `StoreHost`
  # declares the association. An Agent owns its delivery address; a
  # human manages runners. Both are executor associations, but never the
  # same rows.
  has_many :executors, foreign_key: :agent_id, inverse_of: :agent,
    dependent: :destroy
  has_many :managed_executors, class_name: "Executor", foreign_key: :manager_id,
    inverse_of: :manager, dependent: :destroy
  has_many :mcp_connections, foreign_key: :owner_id, inverse_of: :owner, dependent: :destroy
  # The Agents this Human is responsible for: their management surface, and
  # the scope every steward command resolves within.
  has_many :stewarded_agents, -> { where(kind: :agent).where.not(role: :system) },
    class_name: "User", foreign_key: :steward_id, inverse_of: :steward

  enum :kind, %w[human agent].index_by(&:itself), validate: true, scopes: false
  enum :status, %w[active suspended removed].index_by(&:itself), default: :active, validate: true, scopes: false

  before_validation :freeze_initial_steward_shutdown_generation, on: :create

  # Member listings and addressability exclude the synthetic system user.
  scope :members, -> { where.not(role: :system) }
  scope :order_by_display_name, -> { order(:display_name, :id) }
  scope :matching_name_or_handle, ->(query) {
    if query.present?
      pattern = "%#{sanitize_sql_like(query)}%"
      handle_pattern = "%#{sanitize_sql_like(query.delete_prefix("@"))}%"
      where("users.display_name ILIKE :pattern OR users.handle ILIKE :handle_pattern", pattern: pattern, handle_pattern: handle_pattern)
    end
  }
  # The payer's side of usage attribution: a Human pays for its own work and
  # for every Agent it currently stewards.
  scope :billed_to, ->(payer_id) { where(id: payer_id).or(where(steward_id: payer_id)) }

  validates :display_name, presence: true
  validates :display_name, length: { maximum: DISPLAY_NAME_MAX_LENGTH }, allow_nil: true
  validates :identity, presence: true, if: :human?
  validates :identity, absence: true, unless: :human?
  # Steward attribution in the frozen kind/role vocabulary: every non-system
  # agent member has one; humans and the system user never do.
  validates :steward, presence: true, if: :agent_member?
  validates :steward, absence: true, if: -> { human? || system? }
  # The logical-registration-stable, non-secret identifier: exact,
  # case-sensitive, printable, never on humans or the system user.
  validates :agent_identifier, absence: true, if: -> { human? || system? }
  validates :agent_identifier, presence: true, if: :agent_member?
  validates :agent_identifier,
    length: { maximum: AGENT_IDENTIFIER_MAX_LENGTH },
    format: { with: /\A[[:print:]]+\z/ },
    allow_nil: true
  # One instance identifier belongs to one Human in the Account; the format rule
  # already rejects NUL, so uniqueness skips it to avoid an adapter error.
  validates :agent_identifier,
    uniqueness: { scope: :account_id },
    if: :agent_key_changed?,
    unless: -> { agent_identifier.nil? || agent_identifier.include?("\0") }
  validate :owner_must_be_human
  validate :system_must_be_agent
  validate :agent_member_role_is_member
  validate :suspension_is_human_only
  validate :steward_must_be_eligible_at_assignment
  validate :agent_identifier_has_no_surrounding_whitespace

  def email
    identity&.email
  end

  # Gates Agent member/data authentication, unbound rotation, connection and
  # consume; bound executor transport stays independent so already-directed
  # work can reconcile.
  def steward_live?
    return true unless agent_member?

    steward&.active? &&
      applied_steward_shutdown_generation ==
        steward.managed_resource_shutdown_generation
  end

  # ── StoreHost: the principal's own answers ────

  # The profile store belongs to the acting User; an Agent never reaches its
  # steward's store through this scope. Another principal's store is concealed
  # by the route and refused by the writer, which rechecks identity and liveness
  # under the host row's lock.
  def store_write_refusal(user)
    if user.id != id
      :not_found
    elsif !(user.active? && (user.human? || user.steward_live?))
      :workspace_not_active
    end
  end

  # The acting user's row IS the host, the steward's follows —
  # `PrincipalLocks`' order on one table; no second row to serialize on.
  def with_store_create_lock(writer)
    transaction { yield lock_writer(writer) }
  end

  # NO receipt table for the profile store: the partial unique index and
  # the `lock_version` CAS are the convergence contract, so a repeat is
  # `key_taken`, never doubled and never replayed.
  def store_create_receipts(acting_user:, idempotency_key:, request_digest:) = nil

  # The Human this principal's work answers to: its steward for an Agent,
  # itself for a Human, nil for the system User. This relation selects a payer
  # or persona owner; it grants no access to that Human's memory collections.
  def controlling_human = agent? ? steward : self

  # THE UPLOAD ANCHOR: the one write that names this member as an upload's
  # creator, and the scope its own staged rows resolve under — one
  # polymorphic method beside `Executor#content_upload_anchor`, never
  # an `is_a?` branch at the door.
  def content_upload_anchor = { creating_user: self }

  # Execution-principal operability, one gate among the owning services'
  # Workspace, dedication and generation fences — not a complete admission decision.
  def execution_principal_eligible?
    agent_member? && active? && steward_live?
  end

  # Steward reassignment: agent-only, closed outcomes; the
  # assignment-time validation owns eligibility.
  def change_steward(to:)
    if !agent? || system?
      :not_agent
    else
      with_lock do
        source_id = steward_id
        humans = self.class
          .where(id: [source_id, to&.id].compact, account_id: account_id, kind: :human)
          .order(:id)
          .lock
          .index_by(&:id)
        source = humans[source_id]
        target = humans[to&.id]

        if !target&.active?
          :invalid_steward
        else
          # After Agent and both Humans: a removal that wins first creates
          # a durable mismatch rebinding cannot escape.
          address = Executor.live.addressing(self).lock.first
          if source.nil? || steward_shutdown_pending_for?(source) ||
              address&.shutdown_pending_for?(source)
            :shutdown_pending
          else
            self.steward = target
            self.applied_steward_shutdown_generation =
              target.managed_resource_shutdown_generation
            if save
              ConversationLink.close_for_principal(self, reason: "steward_changed") if source_id != target.id
              # Discard the copy `shutdown_pending_for?` may have cached before
              # the Profile write; assigning would write the create-frozen FK.
              address.association(:agent).reset if address
              address&.adopt_human_shutdown_generation(target)
              :changed
            else
              reload
              :invalid_steward
            end
          end
        end
      end
    end
  rescue ActiveRecord::RecordNotUnique
    # The index remains the final backstop for writes outside the sanctioned
    # lock protocol. Preserve this command's closed result instead of leaking a
    # storage race through the administrator surface.
    reload
    :invalid_steward
  end

  private

    def freeze_initial_steward_shutdown_generation
      return unless agent_member? && steward

      self.applied_steward_shutdown_generation =
        steward.managed_resource_shutdown_generation
    end

    def steward_shutdown_pending_for?(human)
      applied_steward_shutdown_generation !=
        human.managed_resource_shutdown_generation
    end

    def agent_key_changed?
      will_save_change_to_steward_id? || will_save_change_to_agent_identifier?
    end

    def owner_must_be_human
      if owner? && !human?
        errors.add(:role, :owner_must_be_human)
      end
    end

    def system_must_be_agent
      if system? && !agent?
        errors.add(:role, :system_must_be_agent)
      end
    end

    def agent_member_role_is_member
      if agent_member? && !member?
        errors.add(:role, :agent_must_be_member)
      end
    end

    def suspension_is_human_only
      if agent? && suspended?
        errors.add(:status, :invalid)
      end
    end

    # Liveness is an assignment-time rule: a steward suspended later blocks
    # the agent at its next authentication (live check), not this row's
    # unrelated saves.
    def steward_must_be_eligible_at_assignment
      if will_save_change_to_steward_id? && steward &&
          !(steward.human? && steward.active? && steward.account_id == account_id)
        errors.add(:steward, :not_eligible)
      end
    end

    def agent_identifier_has_no_surrounding_whitespace
      if agent_identifier && agent_identifier != agent_identifier.strip
        errors.add(:agent_identifier, :invalid)
      end
    end
end
