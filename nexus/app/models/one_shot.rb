# The public aggregate for direct model work. Status is read from its
# LATEST ModelInvocation, never stored here: one, or two when a provider's
# classifier declined the first and the creator's declared fallback ran it
# again (`OneShots::Fallback`).
class OneShot < ApplicationRecord
  # The frozen v1 reclamation window: a kernel constant, never an Account
  # setting, so no configuration surface may reach it.
  RETENTION_PERIOD = 30.days

  attr_readonly :account_id, :workspace_id, :creating_user_id, :public_id,
    :workload

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { workspace&.account }
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"

  has_many :model_invocations, dependent: :destroy, inverse_of: :one_shot
  # The latest execution, which every reader of the run means: the model it
  # runs on, its status, its result.
  has_one :model_invocation, -> { order(id: :desc) }, inverse_of: :one_shot
  has_many :content_bodies, dependent: :destroy, inverse_of: :one_shot
  # The replay stream lives and dies with its OneShot: the drain deletes it
  # child-first on the batch path, and these cascades are what carry the
  # Account-incineration path (items ride each event's delete_all).
  has_many :one_shot_events, dependent: :destroy
  # No dependent option: every item is owned by an envelope above, whose
  # destroy already takes it; this association exists for the sequence reads.
  has_many :one_shot_event_items
  has_one :one_shot_event_cursor, dependent: :destroy


  validates :workload, presence: true
  validates :workload, inclusion: { in: Nexus::ModelWorkloads::ALL }, allow_nil: true
  validate :creator_must_share_the_account

  # A tombstoned OneShot is gone as far as any product surface is concerned;
  # it survives only as rows waiting out the reclamation window.
  scope :listable, -> { where(tombstoned_at: nil) }

  # The OneShot door's funnel for ONE row: listable under a browsable
  # workspace the principal can read — the host's word, as the
  # conversation and the loop answer it. A body this row owns (its
  # input) is readable by whoever can read the row.
  def visible_to?(user)
    !tombstoned? && workspace.browsable? && workspace.data_accessible_by?(user)
  end

  def readable_by?(user) = visible_to?(user)
  scope :tombstoned_before, ->(cutoff) { where(tombstoned_at: ..cutoff) }

  # The one status answer, derived. A OneShot without its invocation is
  # a half-built aggregate, never a legal durable state. A declined answer
  # completed its call and failed the run (`work_status`) — and until the
  # terminal converger has recorded it (or an overloaded one) the run reads
  # `running`: that record is where what the failure comes to is decided —
  # the fallback's execution or the stand — so no reader, follower or
  # tombstone acts on a verdict before it exists.
  def status
    invocation = model_invocation
    return nil if invocation.nil?
    return "running" if invocation.undecided?

    invocation.work_status
  end

  def terminal? = ModelInvocation::TERMINAL_STATUSES.include?(status)

  def tombstoned? = tombstoned_at.present?

  private

    def creator_must_share_the_account
      return if creating_user.nil? || account_id.nil?

      errors.add(:creating_user, :cross_account) unless
        creating_user.account_id == account_id
    end
end
