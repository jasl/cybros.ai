# One candidate version of a turn's content (SillyTavern's swipes). Content
# and reasoning are two role-typed ContentBodies pointing here — the
# thinking/result separation the owner required.
class ConversationTurnVariant < ApplicationRecord
  validates :memory_context, memory_context: true
  STATUSES = ConversationTurn::STATUSES
  ACTIVE_STATUSES = ConversationTurn::ACTIVE_STATUSES
  # `fallback` is the kernel's own regeneration of a direct reply a
  # provider's classifier declined, on the answerer's declared fallback
  # model — told apart from a person's `inference` sample, and never
  # itself switched again.
  SOURCES = %w[manual edit inference run import fork fallback].freeze

  attr_readonly :account_id, :conversation_turn_id, :public_id, :source,
    :origin_variant_id, :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled, :context_mode

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { conversation_turn&.account }
  belongs_to :conversation_turn
  belongs_to :origin_variant, class_name: "ConversationTurnVariant", optional: true
  # Nullify-FK plus the frozen model selection snapshot
  # beside it: the trace outlives the invocation's reap (the house ledger
  # pattern), and the snapshot is what gates same-model reasoning replay.
  belongs_to :model_invocation, optional: true
  # The seam's other side: one loop per variant. No `dependent` — the apex
  # undo tombstones the loop first and the FK nullifies.
  has_one :agent_run

  has_many :content_bodies, dependent: :destroy

  # Hard delete is cascade-only: a bare `destroy` would SET NULL
  # `turns.active_variant_id` without any turn row saving. `prepend` refuses
  # before the bodies cascade.
  before_destroy :hard_delete_rides_a_turn_cascade, prepend: true

  enum :status, STATUSES.index_by(&:itself), validate: true, scopes: false
  validates :source, inclusion: { in: SOURCES }
  # The input row leaves the queue; its prompt's mode must survive with
  # the body. Neither a plain string nor absent instructions identifies raw.
  validates :context_mode, inclusion: { in: ConversationInput::CONTEXT_MODES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :origin_variant_is_a_sibling
  validate :frozen_prefix_takes_no_new_work
  validate :only_a_terminal_variant_soft_deletes
  validate :concealment_waits_for_the_active_pointer
  validate :restore_needs_a_free_slot


  scope :live, -> { where(deleted_at: nil) }
  # Active executions settle normally. A held reply may finish its retry
  # before REOPEN runs: settle that still-rendered tail directly to its final
  # shape. Failed holds and reasoned cancellation already project as failed,
  # so they must not repeatedly narrate the same state on recurring sweeps.
  scope :settling_from_loop, -> {
    where(source: "run", deleted_at: nil)
      .joins(:agent_run, :conversation_turn)
      .where(<<~SQL.squish, active: ACTIVE_STATUSES)
        (conversation_turn_variants.status IN (:active)
          AND (agent_runs.status IN ('needs_attention', 'completed', 'canceled')
            OR agent_runs.delivered_at IS NOT NULL))
        OR (conversation_turn_variants.status = 'failed'
          AND conversation_turns.kind = 'direct_reply'
          AND conversation_turns.active_variant_id = conversation_turn_variants.id
          AND (agent_runs.status = 'completed' OR agent_runs.delivered_at IS NOT NULL
            OR (agent_runs.status = 'canceled' AND agent_runs.failure_reason IS NULL))
          AND NOT #{ConversationTurn::SUCCESSOR_EXISTS}
          AND NOT EXISTS (SELECT 1 FROM conversation_turn_variants candidates
            WHERE candidates.conversation_turn_id = conversation_turn_variants.conversation_turn_id
              AND candidates.deleted_at IS NULL AND candidates.status IN (:active)))
      SQL
  }

  def deleted? = deleted_at.present?
  def terminal? = ConversationTurn::TERMINAL_STATUSES.include?(status)
  def fallback? = source == "fallback"
  # A fork reads its inherited deck through its own ACL, including the
  # pictures bound to those ancestor variants. Its closure and concealment
  # bound this authority exactly as they bound the deck read.
  def readable_by?(user)
    turn = conversation_turn
    source = turn.conversation
    return true if source.visible_to?(user)
    return false if deleted? || !source.workspace.browsable? || !source.workspace.data_accessible_by?(user)

    inheritors = ConversationAncestry.where(
      ancestor_conversation_id: source.id, boundary_position: turn.position..
    )
    concealed = ConversationTurnOverride.where(conversation_turn_id: turn.id).where.not(deleted_at: nil)
    Conversation.visible_to(user, workspace: source.workspace)
      .where(id: inheritors.select(:conversation_id))
      .where.not(id: concealed.select(:conversation_id)).exists?
  end

  # Listings read these columns without loading the full content body.
  def update_content_preview(text)
    update!(
      content_preview: text&.slice(0, 140),
      content_size_bytes: text&.bytesize
    )
  end

  # The seam's one transition: the loop's turn shape lands on this variant
  # and its turn, the `active_turn` pointer following — released at a
  # terminal, re-taken at the reopen. A person's manual or edit sibling keeps
  # the turn: their answer stands and this row is only the deck's.
  def settle(status:)
    update!(status: status)
    turn = conversation_turn
    return if overridden_on?(turn)

    # A terminated regeneration keeps its previous completed answer, just
    # like an inference sample. A needs-attention loop still activates its
    # failed candidate: that hold remains adjudicable and can reopen.
    fallback = %w[failed canceled].include?(status) && agent_run.terminal? &&
      turn.active_variant_id != id && turn.active_variant&.completed?
    if fallback
      turn.update!(status: "completed")
    else
      turn.update!(status: status, active_variant: self)
    end
    conversation = turn.conversation
    updates = { last_activity_at: Time.current }
    if ConversationTurn::ACTIVE_STATUSES.include?(status)
      updates[:active_turn_id] = turn.id
    elsif conversation.active_turn_id == turn.id
      updates[:active_turn_id] = nil
    end
    if status == "completed" && turn.visibility == "visible"
      updates[:context_revision] = conversation.context_revision + 1
    end
    conversation.update!(updates)
  end

  private

    def overridden_on?(turn)
      active = turn.active_variant
      active && active.id != id && %w[manual edit].include?(active.source)
    end

    def hard_delete_rides_a_turn_cascade
      return if destroyed_by_association

      raise ActiveRecord::RecordNotDestroyed.new(
        "a variant hard-deletes only with its turn; conceal with deleted_at",
        self
      )
    end

    def origin_variant_is_a_sibling
      return if origin_variant.nil?
      return if origin_variant.conversation_turn_id == conversation_turn_id

      errors.add(:origin_variant, :invalid)
    end

    # The turn-side freeze's variant twin, so a "regeneration" cannot land
    # mid-history through this table while the turn's own guard holds.
    def frozen_prefix_takes_no_new_work
      return unless new_record? || status_changed?
      turn = conversation_turn
      return if turn.nil?
      return unless (turn.reference? && turn.active_variant_id.present?) ||
        turn.conversation.conversation_turns.above(turn.position).exists?

      errors.add(:base, :frozen_turn)
    end

    # The one-active-candidate index EXCLUDES deleted rows, so soft-deleting
    # a running variant would free the slot while the work still runs: the
    # work ends first.
    def only_a_terminal_variant_soft_deletes
      return unless deleted_at_changed? && deleted_at.present?
      return if terminal?

      errors.add(:deleted_at, :invalid)
    end

    # "Active variant must be live" runs only on turn saves, so the pointer
    # moves under the conversation lock first, then the candidate may hide.
    def concealment_waits_for_the_active_pointer
      return if new_record?
      return unless deleted_at_changed? && deleted_at.present?
      return unless ConversationTurn.exists?(active_variant_id: id)

      errors.add(:deleted_at, :invalid)
    end

    # Restore never touches the active pointer; a live sibling holding the freed
    # slot is an honest refusal, not a unique-index error.
    def restore_needs_a_free_slot
      return if new_record?
      return unless deleted_at_changed? && deleted_at.nil?
      return unless self.class.live
        .where(conversation_turn_id: conversation_turn_id, position: position)
        .where.not(id: id).exists?

      errors.add(:deleted_at, :invalid)
    end
end
