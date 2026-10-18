# One candidate version of a turn's content (SillyTavern's swipes). Content
# and reasoning are two role-typed ContentBodies pointing here — the
# thinking/result separation the owner required.
class Variant < ApplicationRecord
  include ConfiguredExecution
  include ModelSelectionCapture
  validates :memory_context, memory_context: true
  STATUSES = Turn::STATUSES
  ACTIVE_STATUSES = Turn::ACTIVE_STATUSES
  # `fallback` is the kernel's own regeneration of a direct reply a
  # provider's classifier declined, on the execution's next declared model.
  # Its origin joins the same recovery chain; a person's `inference` sample
  # starts an independent chain even when it has an origin for prompt reuse.
  SOURCES = %w[manual edit inference run import fork fallback].freeze

  attr_readonly :account_id, :turn_id, :public_id, :source,
    :origin_variant_id, :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled, :context_mode,
    :agent_configuration, :model_selection, :fallback_models

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { turn&.account }
  belongs_to :turn
  belongs_to :origin_variant, class_name: "Variant", optional: true
  # Nullify-FK plus the frozen model selection snapshot
  # beside it: the trace outlives the invocation's reap (the house ledger
  # pattern), and the snapshot is what gates same-model reasoning replay.
  belongs_to :model_invocation, optional: true
  # The seam's other side: one Run per variant. No `dependent` — the apex
  # undo tombstones the Run first and the FK nullifies.
  has_one :run

  has_many :content_bodies, dependent: :destroy

  # Hard delete is cascade-only: a bare `destroy` would SET NULL
  # `turns.active_variant_id` without any turn row saving. `prepend` refuses
  # before the bodies cascade.
  before_destroy :hard_delete_rides_a_turn_cascade, prepend: true

  enum :status, STATUSES.index_by(&:itself), validate: true, scopes: false
  validates :source, inclusion: { in: SOURCES }
  # The input row leaves the queue; its prompt's mode must survive with
  # the body. Neither a plain string nor absent instructions identifies raw.
  validates :context_mode, inclusion: { in: Input::CONTEXT_MODES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :origin_variant_is_a_sibling
  validate :frozen_prefix_takes_no_new_work
  validate :only_a_terminal_variant_soft_deletes
  validate :concealment_waits_for_the_active_pointer
  validate :restore_needs_a_free_slot


  scope :live, -> { where(deleted_at: nil) }
  # Active executions settle normally. A held reply may finish its retry
  # before REOPEN runs: settle that still-rendered tail directly to its final
  # shape, including a retried cost-held compaction summary. Failed holds and
  # reasoned cancellation already project as failed,
  # so they must not repeatedly narrate the same state on recurring sweeps.
  # A summary whose cost hold became an ordinary failure still owes the input
  # queue a wake, even if its retry finished before the variant reopened.
  scope :settling_from_loop, -> {
    where(source: "run", deleted_at: nil)
      .joins(:run, :turn)
      .where(<<~SQL.squish, active: ACTIVE_STATUSES)
        (variants.status IN (:active)
          AND (runs.status IN ('needs_attention', 'completed', 'canceled')
            OR runs.delivered_at IS NOT NULL))
        OR (variants.status = 'failed'
          AND turns.kind IN ('direct_reply', 'compaction_summary')
          AND turns.active_variant_id = variants.id
          AND (runs.status = 'completed' OR runs.delivered_at IS NOT NULL
            OR (runs.status = 'canceled' AND runs.failure_reason IS NULL)
            OR (turns.kind = 'compaction_summary'
              AND runs.status = 'needs_attention'
              AND runs.attention_reason = 'deliverable_unresolved'))
          AND NOT #{Turn::SUCCESSOR_EXISTS}
          AND NOT EXISTS (SELECT 1 FROM variants candidates
            WHERE candidates.turn_id = variants.turn_id
              AND candidates.deleted_at IS NULL AND candidates.status IN (:active)))
      SQL
  }

  def deleted? = deleted_at.present?
  def terminal? = Turn::TERMINAL_STATUSES.include?(status)
  def fallback? = source == "fallback"
  def execution_agent = turn.execution_agent

  def execution_chain
    chain = [self]
    # Each fallback walks to its earlier origin; the first authored sample ends the chain.
    chain << chain.last.origin_variant while chain.last.fallback?
    chain
  end

  # A fork reads its inherited deck through its own ACL, including the
  # pictures bound to those ancestor variants. Its closure and concealment
  # bound this authority exactly as they bound the deck read.
  def readable_by?(user)
    turn = self.turn
    source = turn.conversation
    return true if source.visible_to?(user)
    return false if deleted? || !source.workspace.browsable? || !source.workspace.data_accessible_by?(user)

    inheritors = ConversationAncestry.where(
      ancestor_conversation_id: source.id, boundary_position: turn.position..
    )
    concealed = TurnOverride.where(turn_id: turn.id).where.not(deleted_at: nil)
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

  # The seam's one transition: the Run's turn shape lands on this variant
  # and its turn, the `active_turn` pointer following — released at a
  # terminal, re-taken at the reopen. A person's manual or edit sibling keeps
  # the turn: their answer stands and this row is only the deck's.
  def settle(status:)
    update!(status: status)
    turn = self.turn
    return if overridden_on?(turn)

    # A terminated regeneration keeps its previous completed answer, just
    # like an inference sample. A needs-attention Run still activates its
    # failed candidate: that hold remains adjudicable and can reopen.
    fallback = %w[failed canceled].include?(status) && run.terminal? &&
      turn.active_variant_id != id && turn.active_variant&.completed?
    if fallback
      turn.update!(status: "completed")
    else
      turn.update!(status: status, active_variant: self)
    end
    conversation = turn.conversation
    updates = { last_activity_at: Time.current }
    if Turn::ACTIVE_STATUSES.include?(status)
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
      return if origin_variant.turn_id == turn_id

      errors.add(:origin_variant, :invalid)
    end

    # The turn-side freeze's variant twin, so a "regeneration" cannot land
    # mid-history through this table while the turn's own guard holds.
    def frozen_prefix_takes_no_new_work
      return unless new_record? || status_changed?
      turn = self.turn
      return if turn.nil?
      return unless (turn.reference? && turn.active_variant_id.present?) ||
        turn.conversation.turns.above(turn.position).exists?

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
      return unless Turn.exists?(active_variant_id: id)

      errors.add(:deleted_at, :invalid)
    end

    # Restore never touches the active pointer; a live sibling holding the freed
    # slot is an honest refusal, not a unique-index error.
    def restore_needs_a_free_slot
      return if new_record?
      return unless deleted_at_changed? && deleted_at.nil?
      return unless self.class.live
        .where(turn_id: turn_id, position: position)
        .where.not(id: id).exists?

      errors.add(:deleted_at, :invalid)
    end
end
