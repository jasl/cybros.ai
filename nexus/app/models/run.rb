# One lane, one growing graph. Clients author tasks, never nodes or edges (every
# structural mutation flows through one compiler and one append door under this
# row's lock), and read the graph whole as task keys. `revision` counts authored mutations only.
class Run < ApplicationRecord
  include PublicIdentified
  include InputHost
  include EventHost
  include ConfiguredExecution
  include ModelSelectionCapture

  attribute :retained_model, RetainedModel.to_type
  validates :retained_model, store_model: true, allow_nil: true

  # No `failed`: the engine never wrote it — a reasoned cancel IS the Run
  # failing, and the turn shape derives its `failed` from a hold or that
  # cancel.
  STATUSES = %w[
    pending running paused needs_attention canceling completed canceled
  ].freeze
  ADJUDICABLE_STATUSES = %w[running paused needs_attention].freeze
  TERMINAL_STATUSES = %w[completed canceled].freeze
  LIVE_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
  # Growth is legal while the Run can still act on it; append from
  # needs_attention is the designed repair exit.
  APPENDABLE_STATUSES = %w[pending running paused needs_attention].freeze

  # The turn shape of a Run: what its rows say in the frozen turn algebra. Rendered
  # on a standalone Run, written onto a run-backed variant.
  TurnShape = Data.define(:status, :failure_reason_key)

  # The Run door's contract: a message drained as the person's trailing
  # words, nothing that names a model or an assembly.
  INPUT_KINDS = %w[message].freeze
  ADMITTED_INPUT_FIELDS = %i[kind role entries attachments delivery_mode speaker_public_id expected_lock_version].freeze
  # Request hygiene, not a totals cap: sixteen waiting directives is a
  # queue nobody is reading.
  INPUT_QUEUE_LIMIT = 16

  # `approval_mode` and `approval_rules` are FROZEN per turn: the
  # scheduler reads the Run row, never the Agent's newer configuration.
  attr_readonly :account_id, :workspace_id, :creating_user_id,
    :billing_subject_key, :billing_subject_public_id, :variant_id, :conversation_public_id,
    :prompt_mechanism, :approval_mode, :approval_rules, :lifecycle_hooks, :conversation_reach, :memory_context,
    :agent_configuration, :model_selection, :fallback_models

  belongs_to :account, default: -> { workspace&.account }
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"
  belongs_to :deliverable_node, class_name: "Task", optional: true
  # The live seam: nil is a standalone Run. Execution ownership derives
  # through it; the accounting snapshot below never restores a deleted host.
  belongs_to :variant, optional: true
  has_one :turn, through: :variant
  has_one :conversation, through: :turn

  # Accounting keeps its host after an apex undo nullifies the live seam.
  # This snapshot grants no access and never selects the execution host.
  before_validation :capture_conversation_public_id, on: :create

  has_many :tasks, dependent: :restrict_with_exception, inverse_of: :run
  has_many :run_edges, dependent: :restrict_with_exception, inverse_of: :run
  has_many :run_append_receipts, dependent: :delete_all, inverse_of: :run
  has_many :run_create_receipts, dependent: :delete_all, inverse_of: :run
  # No dependent teardown: the reaper drains the invocations leaves-first
  # (`ModelInvocations::DrainSettled`) and a destroy path that forgot to
  # fails loudly here instead of leaking.
  has_many :model_invocations

  # The narration flush: buffered items are written HERE, at the end of
  # the transaction, so the event cursor is the last lock it takes.
  before_commit { Run::Narration.flush }
  # The settle wake: a conversation-owned Run's status or attention write
  # wakes its conversation's converger after commit — never inside the
  # Run lock, which the converger's own order forbids.
  after_commit :wake_conversation_settle, on: :update, if: -> {
    variant_id &&
      (saved_change_to_status? || saved_change_to_attention_reason? || saved_change_to_delivered_at?)
  }

  enum :status, STATUSES.index_by(&:itself), default: :pending, validate: true, scopes: false
  validates :failure_reason, length: { maximum: 64 }, allow_nil: true
  # The mechanism the turn ran under: `raw` sent its input verbatim and the
  # kernel assembled nothing; nil is the kernel's assembly.
  validates :prompt_mechanism, inclusion: { in: User::Configurable::PROMPT_MECHANISMS }, allow_nil: true
  # The approval shell: one of the three words, always (the column is NOT
  # NULL; every writer names it — nothing is defaulted), and the frozen
  # rule list under the one grammar, nil for none.
  validates :conversation_reach, inclusion: { in: %w[workspace subtree] }
  validates :memory_context, memory_context: true
  validates :approval_mode, inclusion: { in: User::Configurable::APPROVAL_MODES }
  validates :approval_rules, bounded_json: { bound: :envelope_bound, shape: Array },
    approval_rules: true, allow_nil: true
  # The FROZEN attribution pair, verified at create through
  # BillingSubjects::CreateOrVerify — never the raw submitted string; the
  # usage-receipt writer copies it per step.
  validates :billing_subject_key, length: { maximum: 128 }, allow_nil: true
  validate :variant_is_run_backed

  # The family's number, named on the model beside InferenceRequest's and
  # Conversation's: a condemned Run's rows survive this long before
  # physical reclamation.
  RETENTION_PERIOD = 30.days

  scope :listable, -> { where(tombstoned_at: nil) }
  scope :tombstoned_before, ->(cutoff) { where(tombstoned_at: ..cutoff) }
  scope :for_agent, ->(public_id) {
    agents = User.where(kind: :agent, public_id: public_id).select(:id)
    hosted = Variant.joins(:turn).where("variants.id = runs.variant_id")
      .where(turns: { answering_user_id: agents })
    where(variant_id: nil, creating_user_id: agents).or(where(hosted.arel.exists))
  }
  # A retry can replace its claimant. These are retained Task facts, not
  # a history of every machine that ever attempted this Run.
  scope :for_executor, ->(public_id) {
    tasks = Task.where("tasks.run_id = runs.id")
    related = tasks.where(target_executor_public_id: public_id)
      .or(tasks.where(claimed_by_executor_public_id: public_id))
    where(related.arel.exists)
  }
  # THE RUN DOOR onto the conversation's rows: a conversation-owned Run is
  # readable iff its conversation is — else a `none` conversation would
  # leak whole through its Run id. A standalone Run has no conversation
  # ACL and uses workspace access rules.
  scope :readable_by, ->(user) {
    hosted = Variant.joins(:turn)
      .where(turns: { conversation_id: Conversation.listable.readable_by(user).select(:id) })
      .select(:id)
    where(variant_id: nil).or(where(variant_id: hosted))
  }
  # The converger's two Run-side arms, both on the live index through the
  # seam. REOPEN: a working Run behind its hold-settled turn that is still
  # the tail with this variant still rendered. REPLACE: a non-terminal Run
  # behind a terminal variant that a successor has passed — unless its reply
  # was delivered: a delivered Run behind a successor is finishing
  # background work the person was told about.
  scope :reopening, -> {
    where(status: %w[running paused])
      .joins(variant: :turn)
      .where(variants: { status: "failed" })
      .where("turns.active_variant_id = variants.id")
      .where.not(Turn::SUCCESSOR_EXISTS)
  }
  scope :behind_a_successor, -> {
    where(status: %w[running paused needs_attention], delivered_at: nil)
      .joins(variant: :turn)
      .where(variants: { status: Turn::TERMINAL_STATUSES })
      .where(Turn::SUCCESSOR_EXISTS)
  }

  # Standalone Runs have no Conversation ACL, but still require current
  # Workspace access. Lists, statistics and point reads share this scope.
  def self.visible_to(user, workspace: nil)
    workspaces = Workspace.data_accessible_to(user).browsable
    workspaces = workspaces.where(id: workspace.id) if workspace
    where(workspace_id: workspaces.select(:id)).listable.readable_by(user)
  end

  def self.writable_by(user, workspace: nil)
    workspaces = Workspace.data_writable_to(user)
    workspaces = workspaces.where(id: workspace.id) if workspace
    hosted = Variant.joins(:turn)
      .where(turns: { conversation_id: Conversation.listable.full_access_by(user).select(:id) })
      .select(:id)
    in_scope = where(workspace_id: workspaces.select(:id)).listable
    in_scope.where(variant_id: nil).or(in_scope.where(variant_id: hosted))
  end

  def terminal? = TERMINAL_STATUSES.include?(status)

  def tombstoned? = tombstoned_at.present?

  # THE REPLY IS FINAL: stamped once by the quiescence site when the
  # deliverable answered and no foreground work remained. Background work
  # still running is the Run's own; the turn reads this, the Run's
  # `completed_at` keeps meaning "nothing remains".
  def delivered? = delivered_at.present?

  # The row that hosts this Run's waiting room and narration: its
  # conversation for a conversation-owned Run, itself for a standalone one.
  def host = conversation || self
  # `find_listable_loop`'s funnel, answered for ONE row: the workspace
  # rule on a standalone Run; a conversation-owned Run follows its
  # conversation (a `none` conversation must not leak through its Run).
  def visible_to?(user)
    return false if tombstoned? || !(workspace.browsable? && workspace.data_accessible_by?(user))

    standalone? || conversation.visible_to?(user)
  end
  def standalone? = variant_id.nil?
  def kernel_result_delivery? = !standalone? && Input::KERNEL_ORIGINS.include?(turn.origin)
  # Write standing on this Run: the conversation's answer for a
  # conversation-owned Run, the workspace's rule standalone. Every Run
  # service reads it off the Run, never off `host` — which stays the
  # waiting-room seam.
  def writable_by?(user) = standalone? ? workspace.writable_by?(user) : conversation.writable_by?(user)
  # Under raw the kernel owns no history: the arm's kernel mode refuses on
  # this Run, and only the agent's own delegate may compact.
  def raw? = prompt_mechanism == "raw"

  # The seam's veto on adjudication: a conversation-owned Run answers a person's
  # verbs while shown, or while regenerating the shown answer. Behind an
  # edit the person has answered for it — the verbs refuse
  # `not_adjudicable`, the converger's REOPEN never matches, and no later
  # completion swaps the override out. Read lock-free early and re-read
  # under the Run lock; a standalone Run is never overridden.
  def overridden?
    return false if standalone?

    active_variant_id = turn.active_variant_id
    variant = self.variant
    return false if Variant::ACTIVE_STATUSES.include?(variant.status) &&
      variant.origin_variant_id == active_variant_id

    active_variant_id != variant_id
  end

  # ONE finder, two associations: a conversation-owned Run reads the turn's own
  # steering rows; a standalone Run reads the rows it hosts. A correction
  # pinned to one candidate must never be consumed by its replacement.
  def steering_inputs
    rows = standalone? ? inputs.steering : turn.steering_inputs
    rows.where(expected_steering_run_public_id: [nil, public_id]).order(:queue_position, :id)
  end

  # The Run-hosted queue: a conversation-owned Run has none — its conversation's
  # queue is the conversation's next turns.
  def follow_up_inputs
    standalone? ? inputs.pending.order(:queue_position, :id) : Input.none
  end

  # The designated answer: named at create, moved by the engine round
  # over round; nil only once a tombstone's reap cleared it. Read the one
  # current row: another instance may have settled a cached association.
  def deliverable = tasks.find_by(id: deliverable_node_id)

  # Every model task that is not a branch, a NULL mark included — SQL's
  # `!= 'branch'` would drop it.
  def mainline_nodes
    tasks.where(type: Tasks::ModelTask.sti_name)
      .where("continuation_source IS DISTINCT FROM ?", Tasks::ModelTask::BRANCH)
  end

  # A mainline round still to run, or running. Its request is sealed the
  # moment it starts, so nothing new can join it.
  def mainline_live? = mainline_nodes.where(status: Task::LIVE_STATUSES).exists?

  # The conversation's last word: the mainline is a chain linked by each
  # round's first read, and its tail is the round no mainline round reads.
  def mainline_tail(nodes: nil)
    if nodes
      mainline = nodes.select { |node| node.model_task? && node.continuation_source != Tasks::ModelTask::BRANCH }
      read_first = mainline.filter_map { |node| node.input_from_node_keys&.first }.to_set
      mainline.reject { |node| read_first.include?(node.node_key) }.max_by(&:id)
    else
      read_first = mainline_nodes.where("cardinality(input_from_node_keys) > 0")
        .pluck(Arel.sql("input_from_node_keys[1] AS first_read"))
      mainline_nodes.where.not(node_key: read_first).order(id: :desc).first
    end
  end

  # One pure function over the row: the Run has no `failed`, so a
  # reasoned cancel IS the Run failing; a hold is a failed turn carrying
  # its attention reason. A DELIVERED Run reads `completed` whatever its
  # status: the turn's word is final, and a hold or a cancel of the
  # orphans later is the Run's alone.
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

  # ── InputHost: the Run door's answers ──────────────────────────────────

  # A conversation-owned Run's door is its conversation's; then absence; then a
  # terminal or dying Run has no next boundary to drain into.
  def input_refusal
    return :conversation_hosted unless standalone?
    return :not_found if tombstoned?

    :run_settled if terminal? || status == "canceling"
  end

  def input_kinds = INPUT_KINDS
  def admitted_input_fields = ADMITTED_INPUT_FIELDS
  def input_queue_limit = INPUT_QUEUE_LIMIT
  def hosts_turns? = false
  # The Run's one turn is in flight from create to terminal, so a steer
  # always binds — the steer-on-idle fallback never fires on this host.
  def steer_binding = :self
  # The scheduler pass is what notices boundaries. One signature across
  # both hosts (InputHost): this door admits no `deliver_at`, so `at` is
  # always nil here and the pass runs now.
  def wake_drain(at: nil) = Runs::ScheduleJob.set(wait_until: at).perform_later(id)
  def note_activity = nil

  # The User the Run's work is judged for and answered as (InputHost's
  # third "whose work" answer): a conversation-owned Run's is its TURN's
  # answerer (the input's addressee, frozen on the turn — the
  # conversation's default only by default); a standalone Run answers as
  # its creator. `creating_user` stays the member whose standing keeps
  # the Run writing; a separately captured Speaker may supply its voice.
  # This one line re-points every executor judgment.
  def answering_user = standalone? ? creating_user : turn.answering_user

  # Hosted runs share their variant's frozen bindings; standalone runs
  # retain their creation-time capture on the run itself.
  def memory_context = standalone? ? self[:memory_context] : variant.memory_context
  def agent_configuration = standalone? ? self[:agent_configuration] : variant.agent_configuration
  def model_selection = standalone? ? self[:model_selection] : variant.model_selection
  def fallback_models = standalone? ? self[:fallback_models] : variant.fallback_models

  # The executor scope's correlation principal, separate from memory bindings.
  def memory_principal = standalone? ? creating_user : conversation.memory_principal(creating_user)

  # The execution Agent is the turn's answerer for a hosted Run and the
  # creator for a standalone Run, when that User is an Agent. Executor
  # addressing follows this identity independently of selected configuration.
  def execution_agent = (answering_user if answering_user.agent?)
  # A standalone Run admits no addressee (`ADMITTED_INPUT_FIELDS` refuses
  # it by name): its every row answers as its creator.
  def answerer_eligible?(_user) = false

  # The default used only when accepting a new Runner call without a target.
  # Conversation-hosted Runs use the conversation's current default; accepted
  # tasks retain their concrete target through later default changes.
  def default_runner = standalone? ? default_runner_executor : conversation.default_runner_executor
  # A standalone Run hosts itself; a conversation-owned Run's host is its
  # conversation, whose own answer lists it.
  def hosted_runs = Run.where(id: id)

  # User pause and deployment maintenance share one virtual clock. The
  # earliest active freeze owns every deadline derivation.
  def effective_now(now = Time.current, maintenance_now: Deployments::Maintenance.effective_now(now))
    now = maintenance_now
    status == "paused" && paused_at.present? ? [paused_at, now].min : now
  end

  # The debt repayment: every transition out of `paused` calls this in the
  # same locked transaction, shifting parked clocks forward by the pause.
  # Wall-clock skew between hosts is accepted — bounded and non-corrupting.
  def unfreeze(now = Time.current)
    return if paused_at.blank?

    now = Deployments::Maintenance.effective_now(now)
    pause_ms = (now - paused_at).in_milliseconds.round
    return unless pause_ms.positive?

    # Every clocked park, the held row included: its approver's clock
    # stood still with the rest.
    tasks
      .where(type: Tasks::PARKED_TYPES,
        status: Task::SWEPT_STATUSES)
      .where.not(await_started_at: nil)
      .update_all(["await_started_at = await_started_at + (? * interval '1 millisecond')",
                   pause_ms])
  end

  # The permanent forced cut survives a completed answer and any later swipe.
  # A graceful stop is represented by canceling/canceled until explicitly forced.
  def stopped? = stopped_at.present?

  def graph_mutable? = APPENDABLE_STATUSES.include?(status) && tombstoned_at.nil? && !stopped?

  # STOPPED BEFORE IT ANSWERED: a stop with no reason of the Run's own —
  # a person's cancel, the kernel's tree stop — in flight or landed, on a
  # reply that was not final. The turn shape's `canceled`, read while the
  # drain is still landing it. A delivered Run's orphan stop and a
  # reasoned cancel (`replaced`, a failure) are not this: their turns
  # stand, and what was owed to them is still owed.
  def canceled_unanswered?
    return false if delivered? || failure_reason.present?

    status == "canceling" || status == "canceled"
  end

  private

    def capture_conversation_public_id
      self.conversation_public_id = variant&.turn&.conversation&.public_id
    end

    # Nothing to settle when the seam vanished inside the same transaction
    # — a side reaped at once under its own stop (Sides::Discard).
    def wake_conversation_settle
      conversation_id = conversation&.id
      Conversations::Turns::ConvergeJob.perform_later(conversation_id, { "run_id" => id }) if conversation_id
    end

    # The invariant lives on the owning side: a manual or edit variant never
    # acquires a Run. No presence — nil is a standalone Run.
    def variant_is_run_backed
      return if variant.nil?
      return if variant.source == "run"

      errors.add(:variant, :invalid)
    end
end
