class Account < ApplicationRecord
  NAME_MAX_LENGTH = 100
  COST_UNIT_MAX_LENGTH = 64

  attr_readonly :public_id

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  # Declaration order is destruction order: FK leaves first. This synchronous
  # cascade is test-and-console teardown, not a product verb.
  has_many :sessions, dependent: :destroy
  # A leaf with three NOT NULL FKs (account, identity, user), so it must fall
  # before users and identities; delete_all because a spent recovery is pure
  # evidence with no dependents of its own.
  has_many :member_recovery_authorizations, dependent: :delete_all
  has_many :invitations, dependent: :destroy
  # Model-work leaves fall before the owners their FKs reference; content
  # bodies before the uploads and fragments their children reference.
  has_many :one_shot_create_receipts, dependent: :destroy
  has_many :content_bodies, dependent: :destroy
  # Attempts precede the aggregate that owns their Invocation: that FK is
  # `on_delete::restrict` on purpose, so a surviving attempt would block
  # the whole teardown at the invocation DELETE.
  has_many :model_invocation_attempts, dependent: :delete_all
  has_many :one_shots, dependent: :destroy
  has_many :model_invocations, dependent: :destroy
  # Conversations go descendants-first because the ancestry pin is a RESTRICT
  # FK; a fork child always out-ids its ancestor, so descending id is the
  # topological order for free.
  has_many :conversation_command_receipts, dependent: :delete_all
  has_many :conversations, -> { order(id: :desc) }, dependent: :destroy
  has_many :actors, dependent: :destroy
  has_many :content_fragments, dependent: :destroy
  has_many :content_uploads, dependent: :destroy
  has_many :workspaces, dependent: :destroy
  has_many :device_authorizations, dependent: :destroy
  has_many :refresh_tokens, dependent: :destroy
  has_many :access_tokens, dependent: :destroy
  has_many :refresh_token_families, dependent: :destroy
  has_many :task_executors, dependent: :destroy
  # Provider policy and credential rows are pure leaves (their only FK is the
  # account), so position is FK-free; delete_all because neither carries
  # dependents or destroy-side effects of its own.
  has_many :model_provider_policies, dependent: :delete_all
  has_many :model_provider_credentials, dependent: :delete_all
  # The provider admission floor: a third pure leaf beside them.
  has_many :model_provider_runtime_states, dependent: :delete_all
  # A session references `users` through `issuing_user_id` and its tasks
  # restrict it, so tasks then sessions fall before `users`; `delete_all`
  # because a session's destroy callbacks are lifecycle, not teardown.
  has_many :model_provider_oauth_tasks, dependent: :delete_all
  has_many :model_provider_oauth_sessions, dependent: :delete_all
  # The ledger is retained until Account incineration and leaves only with
  # it; before `users` because budgets reference User rows, and
  # `delete_all` because every ledger model is `readonly?`.
  has_many :usage_records, dependent: :delete_all
  # The rebuildable statistics planes go with their receipts — missed by the
  # round that added them, caught by the re-audit: the third instance of a
  # table landing without its teardown vertical.
  has_many :model_usage_summaries, dependent: :delete_all
  has_many :model_usage_time_buckets, dependent: :delete_all
  has_many :billing_subjects, dependent: :delete_all
  has_many :usage_budgets, dependent: :destroy
  # Memory pointers reference users (the `user/` rung) and their versions
  # under RESTRICT, so documents fall first, then versions, both before
  # `users`; `delete_all` because the reclaim sweep is the versions' only
  # lifecycle and a teardown owes it nothing.
  has_many :memory_documents, dependent: :delete_all
  has_many :memory_document_versions, dependent: :delete_all
  # Store entries reference users (the profile host) — the conversation
  # and workspace hosts already took theirs above through their own
  # cascades; this line is the user host's.
  has_many :store_entries, dependent: :delete_all
  has_many :users, dependent: :destroy
  has_many :identities, dependent: :destroy

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :execution_details_retention_days,
    numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  # The opaque configure-once cost unit: nil is not-yet-configured and never
  # guessed; the one legal assignment is Accounts::ConfigureCostUnit's nil-only CAS.
  normalizes :cost_unit, with: ->(unit) { unit.strip }
  validates :cost_unit, length: { maximum: COST_UNIT_MAX_LENGTH }, allow_nil: true
  validates :cost_unit, presence: true, unless: -> { cost_unit.nil? }

  class << self
    # Founding is one transaction — Account, system user and the owner's
    # Identity/User pair exist together or not at all; no Workspace is seeded.
    # The singleton unique index backstops overlapping first boots.
    def create_with_owner(account:, owner:)
      # Prepare BCrypt before opening the founding transaction. This new
      # Identity has no existing authority that could become stale; validation
      # and every durable write still succeed or roll back together below.
      identity = Identity.new(
        email: owner.fetch(:email),
        password: owner.fetch(:password),
        password_confirmation: owner.fetch(:password_confirmation),
      )

      transaction do
        create!(**account).tap do |created|
          created.users.create!(
            kind: :agent, role: :system, display_name: User::SYSTEM_DISPLAY_NAME
          )
          identity.account = created
          identity.save!
          created.users.create!(
            kind: :human, role: :owner, identity: identity, display_name: owner.fetch(:display_name)
          )
        end
      end
    end
  end

  def owner
    users.find_by!(role: :owner)
  end

  # Mirrors the (steward, agent_identifier) assignment boundary here so the
  # picker cannot drift from User#change_steward and its validation.
  def steward_candidates_for(agent_profile, query:)
    occupied_steward_ids = users.members
      .where(kind: :agent, agent_identifier: agent_profile.agent_identifier)
      .where.not(id: agent_profile.id)
      .where.not(steward_id: nil)
      .select(:steward_id)
    active_humans_matching(query).where.not(id: occupied_steward_ids)
  end

  # The one people-picker composition: active human members whose display
  # name or identity email contains the query, by display name. The caller
  # applies its own exclusion (the workspace owner, the occupied stewards).
  def active_humans_matching(query)
    candidates = users.members
      .includes(:identity)
      .where(kind: :human, status: :active)

    if query.present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      matching_identity_ids = identities.where("email ILIKE ?", pattern).select(:id)
      candidates = candidates.where(
        "users.display_name ILIKE :pattern OR users.identity_id IN (:identity_ids)",
        pattern: pattern,
        identity_ids: matching_identity_ids
      )
    end

    candidates.order_by_display_name
  end

  DirectMember = Data.define(:outcome, :member, :errors)

  # Mail-less direct creation: Identity with the forced-change flag plus the
  # human membership in one transaction, mirroring invitation acceptance.
  # Validation failures return the offending records' errors.
  def create_direct_member(display_name:, email:, role:, password:, password_confirmation:)
    # This is a new credential with no authority that could become stale, so
    # prepare its BCrypt digest before opening the atomic write transaction.
    identity = identities.build(
      email: email,
      password: password,
      password_confirmation: password_confirmation,
      password_change_required: true
    )
    member = nil
    transaction do
      identity.save!
      member = users.create!(kind: :human, role: role, identity: identity, display_name: display_name)
    end
    DirectMember.new(outcome: :created, member: member, errors: nil)
  rescue ActiveRecord::RecordInvalid => error
    DirectMember.new(outcome: :invalid, member: nil, errors: error.record.errors)
  end

  # The indivisible owner swap: owner-only, targets an active human admin,
  # and both role writes commit together.
  def transfer_ownership(to:, by:)
    # Both membership rows lock in id order so concurrent transfers and
    # per-member role/status commands serialize; every guard below re-reads
    # under the locks, making acceptance order the winner rule.
    transaction do
      [by, to].uniq.sort_by(&:id).each(&:lock!)

      if !by.owner? || !by.active?
        :owner_required
      elsif to.account_id != id || to.role != "admin" || !to.human? || !to.active?
        :target_not_eligible
      else
        by.update!(role: :admin)
        to.update!(role: :owner)
        :transferred
      end
    end
  end
end
