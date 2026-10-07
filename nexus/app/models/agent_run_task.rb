# One graph node behind one public task (node == task): the key and lifecycle
# are this row; countdown and generation never render, edges only as task keys
# (`sources`). Definitions are write-once except a model task's selection: a new
# execution generation may choose another model while old invocations stay sealed.
class AgentRunTask < ApplicationRecord
  # A status names who is being waited on (a dependency, an approver, the
  # kernel, an outside holder with a proof, a person); the kind names what
  # the wait is. Declared, not computed from `descendants` (lazy loading); a test pins it to the union.
  STATUSES = %w[
    queued needs_approval running dispatched awaiting_input
    completed failed canceled timed_out uncertain skipped
  ].freeze
  TERMINAL_STATUSES = %w[completed failed canceled timed_out uncertain skipped].freeze
  # The words a failure rests in until its policy or a person settles it;
  # adjudication (`retry`, `abandon`) reads exactly this set.
  FAILURE_STATUSES = %w[failed timed_out uncertain].freeze
  # Started, not live: quiescence and the graceful drain wait on work that
  # has begun — a queued node has not, and a node held for approval is
  # cancelled by a drain, never waited on. The two holder words inside it
  # (`dispatched`, `awaiting_input`) are each type's own; `clocked?` says
  # which types sit on the park clock.
  STARTED_STATUSES = %w[running dispatched awaiting_input].freeze
  # Before anything was spent: the stop's unstarted cancel, the starvation
  # arm and `waiting_on` all read this set, so a task held for approval is
  # cancelled by a stop and keeps its loop open with a reason until then.
  PRE_DISPATCH_STATUSES = %w[queued needs_approval].freeze
  # Resting for an approver — a person's clock, on the park clock at
  # `AwaitTask::MAX_HOLD`; out of STARTED (a drain cancels it, never waits
  # on it) and out of every inbox frontier but the addressee's.
  HELD_STATUSES = %w[needs_approval].freeze
  # On the park clock: started work with a holder outside the kernel, and
  # a row resting for an approver. The sweep's frontier, the pause shift
  # and the park-deadline index predicate read exactly this set
  # (pinned equal by test/code_style/park_index_predicate_test.rb).
  SWEPT_STATUSES = (STARTED_STATUSES + HELD_STATUSES).freeze
  # Not settled — "is this task still in the graph's future". The wrong set
  # for quiescence and the graceful drain, which wait on STARTED_STATUSES.
  LIVE_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
  # WHO WROTE THE ROW: a round's fan or a composed graph, the append door,
  # or the kernel's own plant. The stage governs `model` rows; the other two
  # are pre-approved by their origin unless a rule names them.
  AUTHORS = %w[model author kernel].freeze
  # THE GRANT: who or what let the call past the stage. `human|agent` is
  # the approver's KIND, never "person", so a transcript tells a
  # delegate's grant from the person's.
  APPROVAL_ORIGINS = %w[mode rule human agent author kernel].freeze
  # `propagate` cascades `skipped` state to dependents; `halt` reserves a
  # failed node for adjudication.
  ON_FAILURE_POLICIES = %w[absorb propagate halt].freeze
  LIFETIMES = %w[turn conversation].freeze
  WAKE_MODES = %w[auto passive].freeze
  # The ADJUDICATION axis, a person's stamp on a failure: `abandoned` by
  # the verb, `canceled` by the branch cancel (AgentRuns::CancelBranch) —
  # the one cancel that RESOLVES, so a blocking consumer runs and reads
  # it. An `absorb` policy resolves its failure by DERIVATION
  # (AgentRuns::Graph.settlement) and stamps nothing: one settlement
  # formula, never a persisted copy of it.
  FAILURE_RESOLUTIONS = %w[abandoned canceled].freeze
  TRANSCRIPT_VISIBILITIES = %w[visible collapsed hidden].freeze
  # WHO a parked row is for: an executor, or — for a tools provider only
  # — a pool named by role alone.
  ADDRESSED_ROLES = %w[agent_application runner tool_provider].freeze
  NODE_KEY_FORMAT = Nexus::StepBounds::NODE_KEY_FORMAT

  include RunnerWrite

  attr_readonly :account_id, :agent_run_id, :node_key, :type, :on_failure,
    :target_executor_id, :target_executor_public_id,
    :lifecycle_event,
    :retry_budget, :transcript_visibility,
    :request_options, :input_from_node_keys, :result_from_node_keys, :expansion_parent_id, :barrier_node_id, :tool_name,
    :tool_input, :timeout_ms, :await_timeout_ms, :ask_options, :ask_multi, :resolution_token,
    :join_mode, :quorum_k, :loser_policy, :tool_definitions,
    :continuation_source, :operation_context, :tool_call_id, :tool_alias, :system_instructions, :fan_on_failure,
    :detached, :compaction, :authored_by, :lifetime, :wake

  belongs_to :account, default: -> { agent_run&.account }
  belongs_to :agent_run, inverse_of: :agent_run_tasks
  # Immediate owner of generated work. Unlike dependency edges this ancestry
  # survives internal joins and separates a script's output from its execution.
  belongs_to :expansion_parent, class_name: "AgentRunTask", optional: true
  # The nearest race whose arms hold this row: the barrier's selection
  # stands for every row placed in its arms and for what they expand into,
  # so no arm row reaches a caller on its own. Readonly like the other
  # authored slots, with ONE sanctioned write after create: an arm's rows
  # precede their barrier in the batch, so `Tasks::Append#mark_arms`
  # stamps them inside the append that creates them all — never later, and
  # no other writer — and the reap nullifies it with the barrier.
  belongs_to :barrier_node, class_name: "AgentRunTask", optional: true
  # Written once per execution generation by the one addressing site at the
  # node's start and cleared by a person's retry — NOT attr_readonly, which
  # raises on that path; "never retargeted within a generation" is the
  # writer's discipline, pinned on the writer.
  # Accepted Runner destination survives approval delivery and every retry.
  # Executor collection may nullify the FK; the UUID remains the target fact.
  belongs_to :target_executor, class_name: "TaskExecutor", optional: true
  belongs_to :addressed_executor, class_name: "TaskExecutor", optional: true
  belongs_to :claimed_by_executor, class_name: "TaskExecutor", optional: true
  # The deciding principal of an approve or a deny; the three fact columns
  # are lifecycle columns written once by the stage or the verb — NOT
  # readonly, like the address.
  belongs_to :approved_by_user, class_name: "User", optional: true
  has_many :outgoing_edges, class_name: "AgentRunEdge", foreign_key: :from_node_id,
    dependent: :restrict_with_exception, inverse_of: :from_node
  has_many :incoming_edges, class_name: "AgentRunEdge", foreign_key: :to_node_id,
    dependent: :restrict_with_exception, inverse_of: :to_node
  # Scheduling dependencies in their creation order. Readers that also need
  # edge attributes load incoming_edges and resolve nodes from their own batch.
  has_many :sources, -> { order(:id) }, through: :incoming_edges, source: :from_node
  has_many :content_bodies, dependent: :destroy, inverse_of: :agent_run_task
  has_many :task_operations, -> { order(:position) }, class_name: "AgentRunTaskOperation",
    dependent: :destroy, inverse_of: :agent_run_task
  has_one :output_body, -> { where(role: "output") }, class_name: "ContentBody", inverse_of: :agent_run_task
  # THE CHILD A `spawn` CALL MINTED: one conversation per call (the unique
  # partial index), nullified at the loop's reap. Read by the envelope
  # (the `conversation=` attribute) and the relay; written by
  # `Conversations::Create`'s parent arm alone.
  has_one :spawned_conversation, class_name: "Conversation", foreign_key: :spawn_node_id,
    inverse_of: :spawn_node

  # The narration flush's other trigger — a transition that moved only
  # tasks still writes its events before this transaction commits.
  before_commit { AgentRun::Narration.flush }

  validates :node_key, presence: true, format: { with: NODE_KEY_FORMAT },
    uniqueness: { scope: :agent_run_id }
  validates :status, inclusion: { in: STATUSES }
  validates :on_failure, inclusion: { in: ON_FAILURE_POLICIES }
  validates :lifetime, inclusion: { in: LIFETIMES }
  validates :lifecycle_event, inclusion: { in: Nexus::LifecycleHooks::EVENTS }, allow_nil: true
  validates :wake, inclusion: { in: WAKE_MODES }
  validates :failure_resolution, inclusion: { in: FAILURE_RESOLUTIONS }, allow_nil: true
  validates :transcript_visibility, inclusion: { in: TRANSCRIPT_VISIBILITIES }
  validates :remaining_dependencies,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :retry_budget,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :error_key, length: { maximum: 64 }, allow_nil: true
  validates :error_detail, length: { maximum: 256 }, allow_nil: true
  validates :addressed_role, inclusion: { in: ADDRESSED_ROLES }, allow_nil: true
  validates :first_runner_write, bounded_json: { bound: :snapshot_bound, shape: Hash }, allow_nil: true
  validates :effect_profile, bounded_json: { bound: :envelope_bound, shape: Hash }, allow_nil: true
  validates :authored_by, inclusion: { in: AUTHORS }
  validates :approval_origin, inclusion: { in: APPROVAL_ORIGINS }, allow_nil: true
  # The machine's own invariants: edge legality and the conjunction
  # invariants, one file.
  include MachineValidations

  validates :operation_context, bounded_json: { bound: :snapshot_bound, shape: Hash }, allow_nil: true
  validate :runner_target_is_a_tool_fact

  def runner_target_is_a_tool_fact
    return if target_executor_public_id.nil? && target_executor_id.nil?

    errors.add(:target_executor_public_id, :invalid) unless tool_call? && target_executor_public_id.present?
    if target_executor && target_executor.public_id != target_executor_public_id
      errors.add(:target_executor_public_id, :target_mismatch)
    end
  end

  belongs_to :selected_model_invocation, class_name: "ModelInvocation", optional: true

  # The public task kind and the state machine are the type's own: each subclass
  # sets the two — the kind is the wire word, no lowering table (node == task
  # stores the task vocabulary directly); the machine is `from => [to,...]`, nil
  # for birth — and every other view is derived, so there is exactly one
  # declaration. The base sets neither.
  class_attribute :transitions, :task_kind, instance_writer: false

  def self.statuses
    @statuses ||= (transitions.keys.compact + transitions.values.flatten).uniq.freeze
  end

  # The approval stage exists iff the type's machine can occupy the state —
  # a fact about the machine, never a flag beside it.
  def self.approval_stage? = statuses.include?("needs_approval")

  def terminal? = TERMINAL_STATUSES.include?(status)
  # The accepted operation is the ownership fact. Ordinary tools without
  # operations and kernel replacement wrappers retain their existing results.
  def operation_owner? = tool_call? && task_operations.exists?
  def started? = STARTED_STATUSES.include?(status)
  # A step's attachment or a result's capture is readable by whoever
  # reads the LOOP: the task read's own funnel.
  def readable_by?(user) = agent_run.visible_to?(user)
  # Resting for an approver: pre-dispatch, on the park clock, listed for
  # its addressee alone.
  def held? = HELD_STATUSES.include?(status)
  def failure? = FAILURE_STATUSES.include?(status)

  # A compaction may replace history only with an actual successful
  # summary. This is an output-use predicate, not the task's lifecycle:
  # a tool can complete while returning an error or no text.
  def usable_summary?
    status == "completed" && !output_summary["is_error"] &&
      output_body&.effective_text.present?
  end

  # THE CANDIDATE RULE, on the row alone: a failure nobody adjudicated and
  # no policy resolves — what `retry`/`abandon` accept and a progress
  # reader shows as failed. The one fact the row cannot see, a settled
  # race it lost, is `Graph.settlement_of`'s edge read.
  def unresolved_failure? = failure? && failure_resolution.nil? && on_failure != "absorb"

  # Behaviour belongs on the type and `is_a?` probing is forbidden
  # (closed_internal_shapes_test), so a caller asks here. `task_kind` is
  # the public spelling of `type`, for the wire only.
  def model_task? = false
  def tool_call? = false
  # The bytes a round's request was sealed with, a stored fact of the body
  # served on the task read; only a model task ever has one.
  def sealed_request_bytes = nil
  def await? = false
  def observing_task? = false
  def delegation? = false
  # A question with nobody assigned to it — the tokenless ask a person
  # answers to write standing; only an await ever says yes.
  def asking? = false
  # A running round holds a provider call the cancel sites terminalize
  # through the converger; a tool park holds none and settles directly.
  def holds_invocation? = false
  # On the park clock (`Parked`): one deadline derivation, one sweep.
  def clocked? = false
  # The park's name in the settle's error keys (`tool_timeout`,
  # `await_failed`), a constant per clocked type; nil off the clock.
  def park_kind = nil
  # The inbox's word for this row, derived from class AND status, rendered
  # on the inbox row and never stored: `tool_call`, `ask`, `approval`, or
  # nil for a row no executor is asked about.
  def inbox_kind = nil
  # A racing join — `any` or a quorum — the one join a reader may name:
  # it reads what the race selected. Only a racing join can answer yes.
  def race? = false
  # A race that has settled absorbs the losers still pointing at it.
  def settled_race? = false

  # THE AWAIT A WAITED `spawn` PARKED: the one outgoing edge from the
  # call to an AwaitTask — what the relay settles, what `status` reads
  # as `parent_waiting`, what a person's cancel of the call detaches.
  # Nil for a detached spawn, and for any other call.
  def spawn_await = outgoing_edges.includes(:to_node).map(&:to_node).find(&:await?)

  # The completion obligation is separate from the spawn's finite wait.
  def spawn_delegation = outgoing_edges.includes(:to_node).map(&:to_node).find(&:delegation?)
end
