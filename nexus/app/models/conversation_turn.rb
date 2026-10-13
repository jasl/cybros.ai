# One slot on the timeline; an inherited entry is the ancestor's row read
# through the closure, sharing its `public_id`. A soft-deleted turn keeps
# its slot, so history never renumbers.
class ConversationTurn < ApplicationRecord
  # `compaction_summary` is the kernel's own row: context at a position, so
  # it gets the closure, overlay and window for free — and never an input kind.
  KINDS = %w[message direct_reply compaction_summary].freeze
  ROLES = %w[user assistant system tool].freeze
  # The frozen terminal algebra, shared with the invocation plane and never
  # re-mapped between aggregates. Messages are born completed.
  STATUSES = %w[pending running completed failed canceled timed_out].freeze
  ACTIVE_STATUSES = %w[pending running].freeze
  TERMINAL_STATUSES = (STATUSES - ACTIVE_STATUSES).freeze
  # `excluded_from_context` stays on the timeline and out of assembly (the
  # EXCLUDE capability); `hidden` leaves the timeline surface too.
  VISIBILITIES = %w[visible excluded_from_context hidden].freeze

  attr_readonly :account_id, :conversation_id, :public_id, :position, :kind,
    :role, :speaker_id, :control_owner_user_id, :answering_user_id, :origin,
    :sender_conversation_public_id, :sender_run_public_id, :sender_task_key,
    :forked_from_turn_public_id, :forked_from_variant_public_id, :input_public_id, :callback_sources

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { conversation&.account }
  belongs_to :conversation
  belongs_to :speaker, class_name: "Speaker"
  belongs_to :control_owner_user, class_name: "User"
  # WHO ANSWERED: on EVERY kind — a reply turn its input's addressee, a
  # message turn and the kernel's summary turn the conversation's
  # answerer at creation (the default here). The loop behind a variant
  # answers as this turn does; `speaker` and `control_owner_user`
  # stay the POSTER's (who asked, who edits), this column is whose
  # engine, runner and declaration answered. Frozen: a regenerated
  # variant derives from the same turn.
  belongs_to :answering_user, class_name: "User", default: -> { conversation&.answering_user }
  belongs_to :active_variant, class_name: "ConversationTurnVariant", optional: true

  has_many :conversation_turn_variants, dependent: :destroy
  # Regenerating a loop-backed answer creates a new loop. A previous
  # candidate's background work may still run after its reply was delivered.
  has_many :agent_runs, through: :conversation_turn_variants
  has_many :conversation_turn_overrides, dependent: :destroy
  # A steering input aimed here dies with its target — without this, the
  # RESTRICT FK turns a turn hard-delete (and every conversation destroy that
  # holds a steering row) into a raw FK violation.
  has_many :steering_inputs, class_name: "ConversationInput",
    foreign_key: :steering_target_turn_id, dependent: :destroy,
    inverse_of: :steering_target_turn

  # Only the apex hard-deletes and it never conceals; `prepend` runs the
  # refusal before the dependent cascades.
  before_destroy :only_the_apex_hard_deletes, prepend: true

  validates :kind, inclusion: { in: KINDS }
  validates :role, inclusion: { in: ROLES }
  enum :status, STATUSES.index_by(&:itself), validate: true, scopes: false
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :callback_sources, bounded_json: { bound: :envelope_bound, shape: Array }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :active_variant_is_a_live_sibling
  validate :frozen_once_a_successor_exists
  validate :inherited_variant_is_immutable
  validate :position_stays_above_the_inherited_prefix, on: :create
  validate :creation_lands_alone_at_the_top, on: :create
  validate :restore_only_while_tail
  validate :only_a_terminal_turn_soft_deletes
  validate :concealment_is_mid_history_only
  validate :speaker_and_owner_share_the_account


  scope :live, -> { where(deleted_at: nil) }
  scope :active, -> { where(status: ACTIVE_STATUSES) }

  def deleted? = deleted_at.present?
  # ONE declaring-profile rule: the turn's answerer, when it is an
  # agent.
  def declaring_profile = (answering_user if answering_user&.agent?)
  # The kernel's own row: a summary standing in for the turns it
  # replaced, authored by no one and editable by no one.
  def compaction_summary? = kind == "compaction_summary"
  # A side owns only this frozen copy of its parent's unfinished turn.
  # The immutable fork provenance distinguishes it from the side's own work.
  def reference? = forked_from_turn_public_id.present? && conversation.side?
  def terminal? = TERMINAL_STATUSES.include?(status)

  # THE RELAY MARKER: a spawned child's settled reply is stamped once its
  # parent has it — as the paired await or as kernel mail — or once it is
  # judged nothing owed. Guarded, never locked: the marker is not a
  # status. The await's loop arbiter and the mail receipt own their
  # respective delivery paths.
  def stamp_relayed
    now = Time.current
    self.class.where(id: id, relayed_at: nil).update_all(relayed_at: now, updated_at: now)
    self
  end

  scope :above, ->(position) { where(position: (position + 1)..) }
  scope :at_or_above, ->(position) { where(position: position..) }

  # The successor test in SQL, for the frontiers that join through this
  # table: `above` spelled against the joined row.
  SUCCESSOR_EXISTS = <<~SQL.squish.freeze
    EXISTS (SELECT 1 FROM conversation_turns successors
            WHERE successors.conversation_id = conversation_turns.conversation_id
              AND successors.position > conversation_turns.position)
  SQL

  # The loop still working, or held, behind this turn — what the cancel
  # verb stops, what the apex undo refuses over, what a successor replaces.
  def live_agent_run = agent_runs.where.not(status: AgentRun::TERMINAL_STATUSES).first

  # A descendant's prefix is frozen even when its source has no local successor.
  def tail?
    return false if deleted?
    return false if reference?
    return false if conversation.conversation_turns.above(position).exists?
    return false if descendant_pinned?

    !conversation.conversation_turns.active.where.not(id: id).exists?
  end

  private

    def descendant_pinned?
      ConversationAncestry.where(ancestor_conversation_id: conversation_id, boundary_position: position..).exists?
    end

    # The cascade always passes. A single-row destroy must be the apex,
    # terminal, and unread by every descendant — a closure bound covering this
    # position means a child still reads this row. The in-process backstop.
    def only_the_apex_hard_deletes
      return if destroyed_by_association

      if reference?
        raise ActiveRecord::RecordNotDestroyed.new("a side reference leaves with its conversation", self)
      end

      unless terminal?
        raise ActiveRecord::RecordNotDestroyed.new(
          "an active turn cannot hard-delete; end the work first", self
        )
      end
      if conversation.conversation_turns.above(position).exists?
        raise ActiveRecord::RecordNotDestroyed.new(
          "only the apex turn hard-deletes; conceal mid-history with deleted_at",
          self
        )
      end
      if descendant_pinned?
        raise ActiveRecord::RecordNotDestroyed.new(
          "a descendant still reads this turn through its closure", self
        )
      end
    end

    def active_variant_is_a_live_sibling
      return if active_variant.nil?
      if active_variant.conversation_turn_id != id
        errors.add(:active_variant, :invalid)
      elsif active_variant.deleted?
        # A soft-deleted candidate cannot be the rendered one: the reader
        # filters deleted variants, so the pointer would name a ghost.
        errors.add(:active_variant, :invalid)
      end
    end

    # A fork child's LOCAL turns live strictly above its inherited range —
    # a local row inside the prefix would collide with an ancestor's position
    # in every assembled read.
    def position_stays_above_the_inherited_prefix
      return if conversation.nil? || position.nil?
      bound = conversation.conversation_ancestries.maximum(:boundary_position)
      return if bound.nil? || position > bound

      errors.add(:position, :invalid)
    end

    # A row above a running turn would wedge it; a row in a below-live gap
    # would rewrite the frozen set a restore depends on. The sanctioned writer
    # allocates from `timeline_position_head` under the lock; this refuses everyone else.
    def creation_lands_alone_at_the_top
      return if conversation.nil? || position.nil?

      if conversation.conversation_turns.active.exists?
        errors.add(:base, :active_turn_holds_the_top)
      end
      if conversation.conversation_turns.at_or_above(position).exists?
        errors.add(:position, :invalid)
      end
    end

    # A concealed turn comes back only where it would again be the live tail;
    # everything under it stayed frozen while hidden, so it reads exactly the
    # prefix it was generated against. Chains restore bottom-up.
    def restore_only_while_tail
      return if new_record?
      return unless deleted_at_changed? && deleted_at.nil?
      return unless conversation.conversation_turns.live.above(position).exists?

      errors.add(:deleted_at, :invalid)
    end

    # The one-active-turn index counts soft-deleted rows (its predicate is
    # status-only), so deleting a running turn would wedge the slot: the
    # active work must end before the row may hide.
    def only_a_terminal_turn_soft_deletes
      return unless deleted_at_changed? && deleted_at.present?
      return if terminal?

      errors.add(:deleted_at, :invalid)
    end

    # The apex never conceals; everything below it conceals freely. Exactly
    # where hard delete is pin-refused, conceal opens — coherent because
    # descendants never consult the shared row's view columns.
    def concealment_is_mid_history_only
      return unless deleted_at_changed? && deleted_at.present?
      return if conversation.conversation_turns.above(position).exists?
      return if descendant_pinned?

      errors.add(:deleted_at, :invalid)
    end

    def speaker_and_owner_share_the_account
      if speaker && speaker.account_id != account_id
        errors.add(:speaker, :invalid)
      end
      if control_owner_user && control_owner_user.account_id != account_id
        errors.add(:control_owner_user, :invalid)
      end
      if answering_user && answering_user.account_id != account_id
        errors.add(:answering_user, :invalid)
      end
    end

    # A turn with a local successor — live or concealed — refuses
    # `active_variant_id` and `status` mutation; only physical removal
    # unfreezes. The regenerate reopen passes because the tail has no successor.
    def frozen_once_a_successor_exists
      return if new_record?
      return unless active_variant_id_changed? || status_changed?
      return if conversation.nil?
      return unless conversation.conversation_turns.above(position).exists?

      errors.add(:base, :frozen_by_successor)
    end

    # Status settlement still converges; only replacing inherited content is forbidden.
    def inherited_variant_is_immutable
      return if new_record?
      return unless active_variant_id_changed?
      return unless descendant_pinned? || (reference? && active_variant_id_was.present?)

      errors.add(:active_variant, :readonly)
    end
end
