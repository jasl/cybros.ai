# The unified envelope: THE message row for humans, peer mail, and
# parent↔subagent mail alike — and the durable waiting room the entry gate
# asked for: a mid-run arrival waits AS THIS ROW.
class ConversationInput < ApplicationRecord
  # What a caller may send — a subset of what may stand on the timeline, so
  # no caller can post an input claiming to be a compaction summary.
  KINDS = %w[message direct_reply].freeze
  ROLES = ConversationTurn::ROLES
  # `assembled` compiles the prompt from what the kernel holds; `raw` submits
  # the verbatim prompt, bounded and window-gated, never enriched.
  CONTEXT_MODES = %w[assembled raw].freeze
  DEFAULT_CONTEXT_MODE = "assembled"
  STATES = %w[pending steering blocked].freeze
  FUTURE_BOUND = 10.years
  UUID_SHAPE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # Every field the door's commands can carry; a host admits a subset.
  DOOR_FIELDS = %i[
    kind role entries attachments delivery_mode visible_in_context context_mode context_options
    expected_context_revision expected_tail_turn_public_id expected_steering_loop_public_id
    provider_id model_ref reasoning_effort request_options expected_lock_version tool_names
    approval_mode instructions answering_user_public_id speaker_actor_public_id deliver_at
  ].freeze

  # The adapter's fence-shape check: a fence the caller asked for must
  # fence, so a malformed one refuses at the parameter boundary.
  def self.uuid_shaped?(value) = UUID_SHAPE.match?(value.to_s)
  # Sender intent: queue drains at turn boundaries and starts an idle recipient
  # immediately; steer joins the current turn — accepted and HELD until the
  # AgentLoop round lands the drain. A principal's input may steer; the kernel's
  # own mail is always `queue`, so a running turn finishes first. At idle,
  # direct_reply starts a turn; passive message mail only joins the history.
  DELIVERY_MODES = %w[queue steer].freeze
  # THE SOURCE KIND of every row — the neutral testimony of sourcing a
  # presenter shows, closed at four words: `person` (a human's word),
  # `agent` (a peer's `send`), `task_result` (a background task's answer
  # that outlived its turn, AgentLoops::Mail) and `child` (a spawned
  # conversation's reply). A caller's row derives its word from its
  # author's kind; the kernel's writers name theirs. (The API says
  # `person` where `users.kind` says `human` — two words on adjacent
  # surfaces, neither is fixed.)
  TASK_RESULT_ORIGIN = "task_result".freeze
  CHILD_ORIGIN = "child".freeze
  ORIGINS = ["person", "agent", TASK_RESULT_ORIGIN, CHILD_ORIGIN].freeze
  # THE KERNEL'S OWN ORIGINS: the named SET every kernel carve-out reads —
  # the read order, the bound, the edit surface, the archive pass, the
  # degrade — never origin presence and never the sender stamp, both of
  # which a peer's `send` carries. A kernel row reads before a principal's,
  # is immutable to them (`kernel_input_immutable`) and is not counted; an
  # `agent` row is a principal's word on every one of those. A new kernel
  # writer adds its word here, because an unlabelled writer is a silent grant.
  KERNEL_ORIGINS = [TASK_RESULT_ORIGIN, CHILD_ORIGIN].freeze

  # The row's traits: the reply lane's rules, the assembly intent, and
  # who the turn is between.
  include Validation
  include ContextOptions
  include Addressing

  attr_readonly :account_id, :host_type, :host_id, :public_id, :kind, :role,
    :delivery_mode, :speaker_actor_id, :authoring_user_id, :answering_user_id, :origin,
    :sender_conversation_public_id, :sender_agent_loop_public_id, :sender_task_key, :expected_steering_loop_public_id,
    :callback_result

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account, default: -> { host&.account }
  # The recipient whose waiting room this row waits in: a Conversation, or a
  # standalone AgentLoop hosting the same door.
  belongs_to :host, polymorphic: true
  belongs_to :speaker_actor, class_name: "Actor"
  belongs_to :authoring_user, class_name: "User"
  # THE ADDRESSEE: who answers this turn — the profile the door resolved
  # from `to:` (@handle or public id), else the host's answerer: a
  # conversation's stored default, a standalone loop's creator. Always
  # the resolved fact, so no reader branches on nil; a later change of
  # the default changes what NEW rows take, and a queued row keeps the
  # addressee it was accepted with (the model trio's rule).
  belongs_to :answering_user, class_name: "User", default: -> { host&.answering_user }
  belongs_to :steering_target_turn, class_name: "ConversationTurn", optional: true

  # Plural to match every other body owner (ContentBodies::Replace speaks
  # `content_bodies`); the input's ROLE SINGLETON — exactly one "input" body
  # — stays the caller obligation the entry gate records.
  has_many :content_bodies, dependent: :destroy

  def content_body = content_bodies.first
  # An input's attachment is readable by whoever reads its HOST: the
  # conversation's or the standalone loop's own funnel.
  def readable_by?(user) = host.visible_to?(user)

  # The words as they will land: a drain reads them, a projection shows them.
  def text = content_body&.effective_text

  # Nil-safe: a record built without a host must add an error, never raise.
  validates :kind, inclusion: { in: ->(input) { input.host&.input_kinds || [] } }
  validates :role, inclusion: { in: ROLES }
  enum :state, STATES.index_by(&:itself), default: :pending, validate: true, scopes: false
  # Prefixed so `origin_agent?` never reads as `User#agent?` beside it.
  enum :origin, ORIGINS.index_by(&:itself), validate: true, scopes: false, prefix: :origin
  validates :delivery_mode, inclusion: { in: DELIVERY_MODES }
  validates :context_mode, inclusion: { in: CONTEXT_MODES }
  validates :queue_position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  # A bound steer names its turn on a host that has turns; a one-turn host
  # binds to itself and the row carries no target.
  validates :steering_target_turn, presence: true, if: -> { steering? && host&.hosts_turns? }
  validates :steering_target_turn, absence: true, unless: -> { steering? && host&.hosts_turns? }
  # Every drained steer renders as the person's trailing user message, and
  # on a loop host every input drains as one: `role: user` only there.
  validates :role, inclusion: { in: %w[user] }, if: -> { steering? || (host && !host.hosts_turns?) }
  # The loop host's field rule, pinned at the column defaults: the door
  # refuses these by name; the row is the backstop.
  with_options if: -> { host && !host.hosts_turns? } do
    validates :provider_id, :model_ref, :reasoning_effort,
      :expected_context_revision, :expected_tail_turn_public_id, absence: true
    validates :context_mode, inclusion: { in: [DEFAULT_CONTEXT_MODE] }
    validates :context_options, :request_options, :tool_names, :approval_mode, :instructions,
      absence: true
    validates :visible_in_context, inclusion: { in: [true] }
    # A loop's one turn is in flight from create to terminal: nothing waits
    # behind it, so nothing on it can wait for a time.
    validates :deliver_at, absence: true
  end
  validates :blocked_reason, presence: true, if: -> { state == "blocked" }
  validates :blocked_reason, absence: true, unless: -> { state == "blocked" }
  validates :request_options, bounded_json: { bound: :envelope_bound, shape: Hash }
  validates :callback_result, bounded_json: { bound: :envelope_bound, shape: Hash }, allow_nil: true
  validates :callback_result, absence: true, unless: :kernel_origin?

  scope :pending, -> { where(state: "pending") }
  scope :steering, -> { where(state: "steering") }
  # DUE: nothing scheduled, or scheduled for a time that has passed. The
  # explicit OR, as the admitter spells its own; a row before its time is
  # neither the head nor a blocker — it is not in the room yet. No fourth
  # state: the column is the fact.
  scope :due, ->(now) { where(deliver_at: nil).or(where(deliver_at: ..now)) }
  # THE READ ORDER: the kernel's set FIRST, then arrival — a read rule
  # the drain and the listing share, never a renumbering;
  # `queue_position` stays the arrival number. Postgres orders `false`
  # before `true`, so the rows in KERNEL_ORIGINS lead; a peer's `send`
  # reads in arrival order like a person's word.
  scope :in_read_order, -> { order(arel_table[:origin].not_in(KERNEL_ORIGINS), :queue_position) }
  # The caller-authored countable set: what the caller-authored queue
  # limit bounds. Peer mail counts — an agent's `send` included; the
  # kernel's own set is not COUNTED against the bound but can meet it.
  scope :caller_authored, -> { where(state: %w[pending steering]).where.not(origin: KERNEL_ORIGINS) }

  # The kernel's own row, BY NAME: what reads first, degrades instead of
  # blocking, passes the bin and is nobody's to change.
  def kernel_origin? = KERNEL_ORIGINS.include?(origin)

  # Immutable receipt provenance, copied before this queue row is consumed.
  def callback_source
    return unless callback_result

    { "input_public_id" => public_id, "origin" => origin,
      "sender_conversation_public_id" => sender_conversation_public_id,
      "sender_agent_loop_public_id" => sender_agent_loop_public_id,
      "sender_task_key" => sender_task_key, "result" => callback_result }
  end

  # Completion mail continues the execution that requested it. A reaped source
  # omits memory rather than restoring the receiver's newer configuration.
  def execution_memory_context
    if kernel_origin? && sender_agent_loop_public_id
      source = AgentLoop.find_by(public_id: sender_agent_loop_public_id)
      source ? source.memory_context : { "bindings" => [] }
    else
      host.memory_context
    end
  end
end
