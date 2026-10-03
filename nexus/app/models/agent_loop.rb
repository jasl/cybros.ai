# One lane, one growing graph. Clients author tasks, never nodes or edges (every
# structural mutation flows through one compiler and one append door under this
# row's lock), and read the graph whole as task keys. `revision` counts authored mutations only.
class AgentLoop < ApplicationRecord
  include InputHost
  include EventHost

  # No `failed`: the engine never wrote it — a reasoned cancel IS the loop
  # failing, and the turn shape derives its `failed` from a hold or that
  # cancel.
  STATUSES = %w[
    pending running paused needs_attention canceling completed canceled
  ].freeze
  TERMINAL_STATUSES = %w[completed canceled].freeze
  LIVE_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
  # Growth is legal while the loop can still act on it; append from
  # needs_attention is the designed repair exit.
  APPENDABLE_STATUSES = %w[pending running paused needs_attention].freeze

  # The turn shape of a loop: what its rows say in the frozen turn algebra. Rendered
  # on a standalone loop, written onto a loop-backed variant.
  TurnShape = Data.define(:status, :failure_reason_key)

  # The loop door's contract: a message drained as the person's trailing
  # words, nothing that names a model or an assembly.
  INPUT_KINDS = %w[message].freeze
  ADMITTED_INPUT_FIELDS = %i[kind role entries attachments delivery_mode expected_lock_version].freeze
  # Request hygiene, not a totals cap: sixteen waiting directives is a
  # queue nobody is reading.
  INPUT_QUEUE_LIMIT = 16

  # `approval_mode` and `approval_rules` are FROZEN per turn: the
  # scheduler reads the loop row, never the profile of the day.
  attr_readonly :account_id, :workspace_id, :creating_user_id,
    :billing_subject_key, :billing_subject_public_id, :conversation_turn_variant_id,
    :prompt_mechanism, :approval_mode, :approval_rules, :lifecycle_hooks

  belongs_to :account, default: -> { workspace&.account }
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"
  belongs_to :deliverable_node, class_name: "AgentLoopNode", optional: true
  # The seam: nil is a standalone loop. The conversation is derived
  # through it, never stored.
  belongs_to :conversation_turn_variant, optional: true
  has_one :conversation_turn, through: :conversation_turn_variant
  has_one :conversation, through: :conversation_turn

  has_many :agent_loop_nodes, dependent: :restrict_with_exception, inverse_of: :agent_loop
  has_many :agent_loop_edges, dependent: :restrict_with_exception, inverse_of: :agent_loop
  has_many :agent_loop_append_receipts, dependent: :delete_all, inverse_of: :agent_loop
  has_many :agent_loop_create_receipts, dependent: :delete_all, inverse_of: :agent_loop
  # No dependent teardown: the reaper drains the invocations leaves-first
  # (`ModelInvocations::DrainSettled`) and a destroy path that forgot to
  # fails loudly here instead of leaking.
  has_many :model_invocations

  # The narration flush: buffered items are written HERE, at the end of
  # the transaction, so the event cursor is the last lock it takes.
  before_commit { AgentLoop::Narration.flush }
  # The settle wake: a loop-backed loop's status or attention write
  # wakes its conversation's converger after commit — never inside the
  # loop lock, which the converger's own order forbids.
  after_commit :wake_conversation_settle, on: :update, if: -> {
    conversation_turn_variant_id &&
      (saved_change_to_status? || saved_change_to_attention_reason? || saved_change_to_delivered_at?)
  }

  enum :status, STATUSES.index_by(&:itself), default: :pending, validate: true, scopes: false
  validates :failure_reason, length: { maximum: 64 }, allow_nil: true
  # The mechanism the turn ran under: `raw` sent its input verbatim and the
  # kernel assembled nothing; nil is the kernel's assembly.
  validates :prompt_mechanism, inclusion: { in: User::AgentConfiguration::PROMPT_MECHANISMS }, allow_nil: true
  # The approval shell: one of the three words, always (the column is NOT
  # NULL; every writer names it — nothing is defaulted), and the frozen
  # rule list under the one grammar, nil for none.
  validates :approval_mode, inclusion: { in: User::AgentConfiguration::APPROVAL_MODES }
  validates :approval_rules, bounded_json: { bound: :envelope_bound, shape: Array },
    approval_rules: true, allow_nil: true
  # The FROZEN attribution pair, verified at create through
  # BillingSubjects::CreateOrVerify — never the raw submitted string; the
  # usage-receipt writer copies it per step.
  validates :billing_subject_key, length: { maximum: 128 }, allow_nil: true
  validate :variant_is_loop_backed

  # The family's number, named on the model beside OneShot's and
  # Conversation's: a condemned loop's rows survive this long before
  # physical reclamation.
  RETENTION_PERIOD = 30.days

  scope :listable, -> { where(tombstoned_at: nil) }
  scope :tombstoned_before, ->(cutoff) { where(tombstoned_at: ..cutoff) }
  # THE LOOP DOOR onto the conversation's rows: a loop-backed loop is
  # readable iff its conversation is — else a `none` conversation would
  # leak whole through its loop id. A standalone loop has no conversation
  # ACL and uses workspace access rules.
  scope :readable_by, ->(user) {
    hosted = ConversationTurnVariant.joins(:conversation_turn)
      .where(conversation_turns: { conversation_id: Conversation.readable_by(user).select(:id) })
      .select(:id)
    where(conversation_turn_variant_id: nil).or(where(conversation_turn_variant_id: hosted))
  }
  # The converger's two loop-side arms, both on the live index through the
  # seam. REOPEN: a working loop behind its hold-settled turn that is still
  # the tail with this variant still rendered. REPLACE: a non-terminal loop
  # behind a terminal variant that a successor has passed — unless its reply
  # was delivered: a delivered loop behind a successor is finishing
  # background work the person was told about.
  scope :reopening, -> {
    where(status: %w[running paused])
      .joins(conversation_turn_variant: :conversation_turn)
      .where(conversation_turn_variants: { status: "failed" })
      .where("conversation_turns.active_variant_id = conversation_turn_variants.id")
      .where.not(ConversationTurn::SUCCESSOR_EXISTS)
  }
  scope :behind_a_successor, -> {
    where(status: %w[running paused needs_attention], delivered_at: nil)
      .joins(conversation_turn_variant: :conversation_turn)
      .where(conversation_turn_variants: { status: ConversationTurn::TERMINAL_STATUSES })
      .where(ConversationTurn::SUCCESSOR_EXISTS)
  }

  def terminal? = TERMINAL_STATUSES.include?(status)

  def tombstoned? = tombstoned_at.present?

  # THE REPLY IS FINAL: stamped once by the quiescence site when the
  # deliverable answered and no foreground work remained. Background work
  # still running is the loop's own; the turn reads this, the loop's
  # `completed_at` keeps meaning "nothing remains".
  def delivered? = delivered_at.present?

  # The row that hosts this loop's waiting room and narration: its
  # conversation for a loop-backed loop, itself for a standalone one.
  def host = conversation || self
  # `find_listable_loop`'s funnel, answered for ONE row: the workspace
  # rule on a standalone loop; a loop-backed loop follows its
  # conversation (a `none` conversation must not leak through its loop).
  def visible_to?(user)
    return false if tombstoned? || !(workspace.browsable? && workspace.data_accessible_by?(user))

    standalone? || conversation.visible_to?(user)
  end
  def standalone? = conversation_turn_variant_id.nil?
  def kernel_mail? = !standalone? && ConversationInput::KERNEL_ORIGINS.include?(conversation_turn.origin)
  # Write standing on this loop: the conversation's answer for a
  # loop-backed loop, the workspace's rule standalone. Every loop
  # service reads it off the loop, never off `host` — which stays the
  # waiting-room seam.
  def writable_by?(user) = standalone? ? workspace.writable_by?(user) : conversation.writable_by?(user)
  # Under raw the kernel owns no history: the arm's kernel mode refuses on
  # this loop, and only the agent's own delegate may compact.
  def raw? = prompt_mechanism == "raw"

  # The seam's veto on adjudication: a loop-backed loop answers a person's
  # verbs while shown, or while regenerating the shown answer. Behind an
  # edit the person has answered for it — the verbs refuse
  # `not_adjudicable`, the converger's REOPEN never matches, and no later
  # completion swaps the override out. Read lock-free early and re-read
  # under the loop lock; a standalone loop is never overridden.
  def overridden?
    return false if standalone?

    active_variant_id = conversation_turn.active_variant_id
    variant = conversation_turn_variant
    return false if ConversationTurnVariant::ACTIVE_STATUSES.include?(variant.status) &&
      variant.origin_variant_id == active_variant_id

    active_variant_id != conversation_turn_variant_id
  end

  # ONE finder, two associations: a loop-backed loop reads the turn's own
  # steering rows; a standalone loop reads the rows it hosts. A correction
  # pinned to one candidate must never be consumed by its replacement.
  def steering_inputs
    rows = standalone? ? conversation_inputs.steering : conversation_turn.steering_inputs
    rows.where(expected_steering_loop_public_id: [nil, public_id]).order(:queue_position, :id)
  end

  # The loop-hosted queue: a loop-backed loop has none — its conversation's
  # queue is the conversation's next turns.
  def follow_up_inputs
    standalone? ? conversation_inputs.pending.order(:queue_position, :id) : ConversationInput.none
  end

  # The designated answer: named at create, moved by the engine round
  # over round; nil only once a tombstone's reap cleared it. Read the one
  # current row: another instance may have settled a cached association.
  def deliverable = agent_loop_nodes.find_by(id: deliverable_node_id)

  # Every model task that is not a branch, a NULL mark included — SQL's
  # `!= 'branch'` would drop it.
  def spine_nodes
    agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name)
      .where("continuation_source IS DISTINCT FROM ?", AgentLoopNodes::ModelTask::BRANCH)
  end

  # A spine round still to run, or running. Its request is sealed the
  # moment it starts, so nothing new can join it.
  def spine_live? = spine_nodes.where(status: AgentLoopNode::LIVE_STATUSES).exists?

  # The conversation's last word: the spine is a chain linked by each
  # round's first read, and its tail is the round no spine round reads.
  def spine_tail(nodes: nil)
    if nodes
      spine = nodes.select { |node| node.round? && node.continuation_source != AgentLoopNodes::ModelTask::BRANCH }
      read_first = spine.filter_map { |node| node.input_from_node_keys&.first }.to_set
      spine.reject { |node| read_first.include?(node.node_key) }.max_by(&:id)
    else
      read_first = spine_nodes.where("cardinality(input_from_node_keys) > 0")
        .pluck(Arel.sql("input_from_node_keys[1] AS first_read"))
      spine_nodes.where.not(node_key: read_first).order(id: :desc).first
    end
  end

  # One pure function over the row: the loop has no `failed`, so a
  # reasoned cancel IS the loop failing; a hold is a failed turn carrying
  # its attention reason. A DELIVERED loop reads `completed` whatever its
  # status: the turn's word is final, and a hold or a cancel of the
  # orphans later is the loop's alone.
  def turn_shape
    return TurnShape.new(status: "completed", failure_reason_key: nil) if delivered?

    case status
    when "pending" then TurnShape.new(status: "pending", failure_reason_key: nil)
    when "running", "paused", "canceling" then TurnShape.new(status: "running", failure_reason_key: nil)
    when "needs_attention" then TurnShape.new(status: "failed", failure_reason_key: attention_reason)
    when "completed" then TurnShape.new(status: "completed", failure_reason_key: nil)
    else
      if failure_reason.present?
        TurnShape.new(status: "failed", failure_reason_key: failure_reason)
      else
        TurnShape.new(status: "canceled", failure_reason_key: nil)
      end
    end
  end

  # ── InputHost: the loop door's answers ──────────────────────────────────

  # A loop-backed loop's door is its conversation's; then absence; then a
  # terminal or dying loop has no next boundary to drain into.
  def input_refusal
    return :conversation_hosted unless standalone?
    return :not_found if tombstoned?

    :agent_loop_settled if terminal? || status == "canceling"
  end

  def input_kinds = INPUT_KINDS
  def admitted_input_fields = ADMITTED_INPUT_FIELDS
  def input_queue_limit = INPUT_QUEUE_LIMIT
  def hosts_turns? = false
  # The loop's one turn is in flight from create to terminal, so a steer
  # always binds — the steer-on-idle fallback never fires on this host.
  def steer_binding = :self
  # The scheduler pass is what notices boundaries. One signature across
  # both hosts (InputHost): this door admits no `deliver_at`, so `at` is
  # always nil here and the pass runs now.
  def wake_drain(at: nil) = AgentLoops::ScheduleJob.set(wait_until: at).perform_later(id)
  def note_activity = nil

  # The User the loop's work is judged for and answered as (InputHost's
  # third "whose work" answer): a loop-backed loop's is its TURN's
  # answerer (the input's addressee, frozen on the turn — the
  # conversation's default only by default); a standalone loop answers as
  # its creator. `creating_user` stays the speaker — the poster whose
  # standing keeps the loop writing and whose Human the `user/` rung
  # resolves to. This one line re-points every executor judgment.
  def answering_user = standalone? ? creating_user : conversation_turn.answering_user

  # The principal whose controlling Human the `user/` rung resolves to:
  # the speaker, except on a spawned child (`Conversation#memory_principal`).
  def memory_context = conversation_turn_variant&.memory_context

  def memory_principal = standalone? ? creating_user : conversation.memory_principal(creating_user)

  # ONE declaring-profile rule: the answerer's, when it is an agent — a
  # loop-backed loop answers as its turn does, whoever authored it; a
  # standalone loop answers as its creator. The agent address derives from
  # THIS, never from `creating_user`.
  def declaring_profile = (answering_user if answering_user.agent?)
  # A standalone loop admits no addressee (`ADMITTED_INPUT_FIELDS` refuses
  # it by name): its every row answers as its creator.
  def answerer_eligible?(_user) = false

  # The binding read at each tool node's start: a loop-backed loop
  # derives its conversation's, exactly as `host` does, so a mid-turn
  # handoff reaches the next round's calls of the same loop.
  def bound_runner = standalone? ? runner_executor : conversation.runner_executor
  # A standalone loop hosts itself; a loop-backed loop's host is its
  # conversation, whose own answer lists it.
  def hosted_agent_loops = AgentLoop.where(id: id)

  # The virtual clock: while paused, time stands still for every
  # deadline derivation — the freeze is the derivation's property, the
  # sweep's status gate only an optimization.
  def effective_now(now = Time.current)
    status == "paused" && paused_at.present? ? [paused_at, now].min : now
  end

  # The debt repayment: every transition out of `paused` calls this in the
  # same locked transaction, shifting parked clocks forward by the pause.
  # Wall-clock skew between hosts is accepted — bounded and non-corrupting.
  def unfreeze(now = Time.current)
    return if paused_at.blank?

    pause_ms = (now - paused_at).in_milliseconds.round
    return unless pause_ms.positive?

    # Every clocked park, the held row included: its approver's clock
    # stood still with the rest.
    agent_loop_nodes
      .where(type: AgentLoopNodes::PARKED_TYPES,
        status: AgentLoopNode::SWEPT_STATUSES)
      .where.not(await_started_at: nil)
      .update_all(["await_started_at = await_started_at + (? * interval '1 millisecond')",
                   pause_ms])
  end

  # The permanent forced cut survives a completed answer and any later swipe.
  # A graceful stop is represented by canceling/canceled until explicitly forced.
  def stopped? = stopped_at.present?

  def graph_mutable? = APPENDABLE_STATUSES.include?(status) && tombstoned_at.nil? && !stopped?

  # STOPPED BEFORE IT ANSWERED: a stop with no reason of the loop's own —
  # a person's cancel, the kernel's tree stop — in flight or landed, on a
  # reply that was not final. The turn shape's `canceled`, read while the
  # drain is still landing it. A delivered loop's orphan stop and a
  # reasoned cancel (`replaced`, a failure) are not this: their turns
  # stand, and what was owed to them is still owed.
  def canceled_unanswered?
    return false if delivered? || failure_reason.present?

    status == "canceling" || status == "canceled"
  end

  private

    # Nothing to settle when the seam vanished inside the same transaction
    # — a side reaped at once under its own stop (Sides::Discard).
    def wake_conversation_settle
      conversation_id = conversation&.id
      Conversations::Turns::ConvergeJob.perform_later(conversation_id, { "agent_loop_id" => id }) if conversation_id
    end

    # The invariant lives on the owning side: a manual or edit variant never
    # acquires a loop. No presence — nil is a standalone loop.
    def variant_is_loop_backed
      return if conversation_turn_variant.nil?
      return if conversation_turn_variant.source == "agent_loop"

      errors.add(:conversation_turn_variant, :invalid)
    end
end
