# One provider attempt: admission, start, terminal and settlement facts.
# No active-attempt partial unique index — every transition runs
# lock -> recheck -> CAS under the parent Invocation.
class ModelInvocationAttempt < ApplicationRecord
  # `priced` settles from recorded tokens, `admitted_free` proved exact zero, `unmetered`
  # declares no money is computed; admission holds nothing. Free is a proven amount, unmetered a
  # refusal to produce one.
  ADMISSION_SHAPES = %w[priced admitted_free unmetered].freeze

  STATUSES = %w[prepared running completed failed canceled timed_out].freeze
  ACTIVE_STATUSES = %w[prepared running].freeze

  # `not_applicable` never owed a receipt, `pending` owes one, `settled` has
  # one, `abandoned` closed the late-evidence window with nothing observed —
  # distinct so the never-observed set stays queryable and the reclamation fence lifts.
  SETTLEMENT_STATES = %w[not_applicable pending settled abandoned].freeze

  attr_readonly :account_id, :model_invocation_id, :public_id, :ordinal, :admission_shape

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :model_invocation

  enum :status, STATUSES.index_by(&:itself), default: :prepared, validate: true, scopes: false
  enum :settlement_state, SETTLEMENT_STATES.index_by(&:itself),
    default: :not_applicable, validate: true, scopes: false

  validates :ordinal, numericality: { only_integer: true, greater_than: 0 }
  validates :admission_shape, inclusion: { in: ADMISSION_SHAPES }
  # The durable sweep finds work by scanning it, so a null one is a row no
  # scan can reach, holding a budget and blocking every later ordinal.
  validates :deadline_at, presence: true
  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def started? = provider_started_at.present?
end
