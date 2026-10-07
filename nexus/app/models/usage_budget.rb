# One explicit-window budget per live User: the owner's kind is the role — Human is payer balance, Agent
# is allowance. Writers own the same parent-before-ledger lock order; the materialized head moves only
# by appended entries. The model pins shape, not sums.
class UsageBudget < ApplicationRecord
  # Snapshot of the owner's kind at creation; the system kind is
  # refused, so it never appears in this vocabulary.
  USER_KINDS = %w[human agent].freeze

  attr_readonly :account_id, :public_id, :user_public_id, :user_kind, :starts_at

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :user

  # delete_all, not destroy: entries are immutable (`readonly?`), so a
  # row-by-row destroy would refuse — and they carry no dependents of their
  # own. Reached only by Account incineration.
  has_many :entries, class_name: "UsageBudgetEntry", dependent: :delete_all

  # New-spend eligibility stays in SQL so a long budget history never becomes
  # an admission-time Ruby scan. The window is half-open at expires_at.
  scope :usable_at, ->(instant) {
    where(revoked_at: nil, starts_at: ..instant)
      .merge(where(expires_at: nil).or(where.not(expires_at: ..instant)))
  }

  validates :user_kind, inclusion: { in: USER_KINDS }
  validates :credited_amount, :debited_amount,
    numericality: { greater_than_or_equal_to: 0 }
  validates :last_entry_sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validate :snapshots_derive_from_the_live_user, on: :create
  validate :window_is_half_open_and_ordered
  validate :window_does_not_overlap_a_usable_sibling
  validate :revoke_evidence_is_whole_or_absent

  def revoked? = revoked_at.present?

  private

    def snapshots_derive_from_the_live_user
      return if user.nil?

      if user.system?
        errors.add(:user, :system_user)
        return
      end
      expected_kind = user.agent? ? "agent" : "human"
      errors.add(:user_kind, :stale_snapshot) if user_kind != expected_kind
      if user_public_id != user.public_id
        errors.add(:user_public_id, :stale_snapshot)
      end
      errors.add(:account_id, :not_the_owners) if account_id != user.account_id
    end

    def window_is_half_open_and_ordered
      return if starts_at.nil? || expires_at.nil?
      return if expires_at > starts_at

      errors.add(:expires_at, :not_after_starts_at)
    end

    # At most one usable window per instant; the User-locked writer owns the race. Two exits
    # keep this from being a retroactive veto: a revoked window collides with nothing, and a
    # head mutation never re-derives the overlap.
    def window_does_not_overlap_a_usable_sibling
      return if starts_at.nil?
      return if revoked?
      return unless new_record? || starts_at_changed? || expires_at_changed?

      siblings = UsageBudget.where(user_id: user_id, revoked_at: nil).where.not(id: id)
      # Half-open on both sides: a sibling ending exactly at starts_at does
      # not overlap.
      overlapping = siblings.where(expires_at: nil)
        .or(siblings.where.not(expires_at: ..starts_at))
      overlapping = overlapping.where(starts_at: ...expires_at) if expires_at
      return unless overlapping.exists?

      errors.add(:starts_at, :overlaps_usable_window)
    end

    def revoke_evidence_is_whole_or_absent
      fields = [revoked_at, revoked_by_public_id, revoke_operation_key]
      return if fields.all?(&:nil?) || fields.none?(&:nil?)

      errors.add(:base, :torn_revoke)
    end
end
