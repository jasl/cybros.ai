# The single execution, cancellation and status authority: queued ->
# running -> terminal, and no second authority beside it.
#
# A declined or errored finish is where the two axes disagree: the call
# COMPLETED — the exchange happened and was billed — while the WORK it was
# for failed, since it has no answer. Every owner reads the work's status
# through `work_status`; the row keeps `completed` with the quality beside it.
class ModelInvocation < ApplicationRecord
  STATUSES = %w[queued running completed failed canceled timed_out].freeze
  # Null is a clean finish. A separate axis from `failure_reason_key`: a
  # truncated answer is a completed run with a caveat, never a failed one.
  FINISH_QUALITIES = SimpleInference::FinishQuality::QUALITIES
  # The failure key of the work a declined call was for — a loop step's
  # error, a direct reply's reason, a one-shot's error code.
  DECLINED_KEY = "model_refused".freeze
  FINISH_ERROR_KEY = "provider_error".freeze
  # The provider refused the sent request for its length: compaction's to
  # answer, on both lanes.
  CONTEXT_OVERFLOW_KEY = "provider_context_overflow".freeze
  # The provider said it was overloaded (503, 529, or the streamed overload
  # event) on EVERY attempt the budget spent: the work's key, and the second
  # trigger of the declared fallback. Each such attempt's receipt carries it.
  OVERLOADED_KEY = "provider_overloaded".freeze
  TERMINAL_STATUSES = %w[completed failed canceled timed_out].freeze
  NONTERMINAL_STATUSES = (STATUSES - TERMINAL_STATUSES).freeze
  INFERENCE_REQUEST_PURPOSE = "inference_request"
  CONVERSATION_REPLY_PURPOSE = "conversation_reply"
  AGENT_RUN_TASK_PURPOSE = "agent_run_task"
  PURPOSES = [INFERENCE_REQUEST_PURPOSE, CONVERSATION_REPLY_PURPOSE, AGENT_RUN_TASK_PURPOSE].freeze
  # The closed purpose matrix, as one table rather than scattered
  # conditionals: each purpose names the association that owns it, and
  # exactly one owner is present on any row.
  PURPOSE_OWNERS = {
    INFERENCE_REQUEST_PURPOSE => :inference_request,
    CONVERSATION_REPLY_PURPOSE => :conversation,
    AGENT_RUN_TASK_PURPOSE => :agent_run,
  }.freeze
  INTERNAL_CREATION_KEY_MAX_BYTES = 64
  CANCELLATION_REASONS = %w[
    workspace_archived workspace_deleted workspace_access_revoked
    user_removed steward_removed creator_requested
  ].freeze
  # The shape-fault switch: a provider's non-transient 4xx of a request
  # carrying native reasoning (429 and 5xx are transient and end as a spent
  # budget). A window overflow is compaction's, never a trace cut.
  REPLAY_REFUSAL_KEYS = %w[provider_http_error].freeze

  attr_readonly :account_id, :creating_user_id, :workspace_id, :inference_request_id,
    :conversation_id, :agent_run_id,
    :public_id, :workload, :purpose, :provider_id, :model_ref,
    :reasoning_effort, :reasoning_enabled, :request_options, :admission_deadline_seconds,
    :priority, :internal_creation_key

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }

  belongs_to :account
  belongs_to :creating_user, class_name: "User"
  # Optional at the database, exactly one required by the model: a NOT NULL
  # only one branch can satisfy would force the other to invent a value.
  belongs_to :workspace, optional: true
  belongs_to :inference_request, inverse_of: :model_invocations, optional: true
  belongs_to :conversation, optional: true
  belongs_to :agent_run, optional: true

  # `request` is the assembled semantic input every retry sends; terminal
  # apply writes `response` and `reasoning`.
  has_many :content_bodies, dependent: :destroy, inverse_of: :model_invocation
  has_one :tool_calls_body, -> { where(role: "tool_calls") }, class_name: "ContentBody", inverse_of: :model_invocation
  has_one :reasoning_trace_body, -> { where(role: "reasoning_trace") }, class_name: "ContentBody", inverse_of: :model_invocation

  # A sealed request's placed picture is readable by whoever reads the
  # host that ran it: the InferenceRequest, the conversation or the loop.
  def readable_by?(user)
    host = inference_request || conversation || agent_run
    host.present? && host.visible_to?(user)
  end
  has_many :attempts, class_name: "ModelInvocationAttempt",
    dependent: :restrict_with_error, inverse_of: :model_invocation
  # Binary outputs as Active Storage attachments: the framework's
  # reference counting and purge, no bespoke attachment plane.
  # `analyze::lazily`: the apply writes each blob once with the sniffed
  # type and nothing reads blob metadata, so no analysis is enqueued.
  has_many_attached :output_files, analyze: :lazily

  # The drains delete invocations in bulk, and Active Storage's purge
  # discipline hangs off record DESTROY — so the purge is said here, once,
  # for the rows a drain is about to delete.
  def self.purge_output_files_later(invocation_ids)
    ActiveStorage::Attachment
      .where(record_type: polymorphic_name, record_id: invocation_ids)
      .find_each(&:purge_later)
  end

  enum :status, STATUSES.index_by(&:itself), default: :queued, validate: true, scopes: false

  before_validation :derive_inference_request_branch, on: :create
  before_validation :derive_conversation_branch, on: :create
  before_validation :derive_agent_run_branch, on: :create

  validate :exactly_one_purpose_owner

  validates :purpose, presence: true
  validates :purpose, inclusion: { in: PURPOSES }, allow_nil: true
  validates :workload, presence: true
  validates :workload, inclusion: { in: Nexus::ModelWorkloads::ALL }, allow_nil: true
  validates :provider_id, presence: true, length: { maximum: 64 }
  validates :model_ref, presence: true, length: { maximum: 128 }
  validates :reasoning_effort, length: { maximum: 32 }, allow_nil: true
  validates :admission_deadline_seconds,
    numericality: { only_integer: true, greater_than: 0 }
  validates :internal_creation_key, presence: true,
    length: { maximum: INTERNAL_CREATION_KEY_MAX_BYTES }
  validates :cancellation_reason,
    inclusion: { in: CANCELLATION_REASONS }, allow_nil: true
  # Bounded, not enumerated: four independently closed vocabularies feed it,
  # so an inclusion list here would be a fifth place to forget.
  validates :failure_reason_key, length: { maximum: 64 }, allow_nil: true
  # Enumerated, unlike the reason above: one vocabulary feeds it, and being
  # closed lets a client key an i18n message off it.
  validates :finish_quality, inclusion: { in: FINISH_QUALITIES }, allow_nil: true
  # The provider's own word beside a declined finish. Bounded, not
  # enumerated, like the failure key: every provider has its own vocabulary
  # (or none), and no kernel decision branches on it.
  validates :refusal_category, length: { maximum: 64 }, allow_nil: true

  scope :queued, -> { where(status: "queued") }
  # A positive IN, not NOT IN over the terminal set: only the literal form
  # proves the nonterminal partial-index predicates.
  scope :nonterminal, -> { where(status: NONTERMINAL_STATUSES) }

  # Selection is already resolved. Each caller owns the request options,
  # creation key and owner, along with the surrounding transaction.
  def self.create_for_selection(selection:, **attributes)
    create!(
      **attributes,
      provider_id: selection.provider_id,
      model_ref: selection.model_ref,
      reasoning_effort: selection.reasoning.effort,
      reasoning_enabled: selection.reasoning.enabled,
      admission_deadline_seconds:
        selection.execution_profile.total_execution_deadline_seconds
    )
  end

  def terminal? = TERMINAL_STATUSES.include?(status)

  def refused? = finish_quality == SimpleInference::FinishQuality::REFUSED
  def blocked? = finish_quality == SimpleInference::FinishQuality::BLOCKED
  def declined? = refused? || blocked?
  def finish_error? = finish_quality == SimpleInference::FinishQuality::ERROR

  # The status of the work: an unusable answer completed the exchange and
  # failed the work, while output-budget cuts still retain usable output.
  def work_status = declined? || finish_error? ? "failed" : status

  def context_overflow? = failed? && failure_reason_key == CONTEXT_OVERFLOW_KEY

  def overloaded? = failed? && failure_reason_key == OVERLOADED_KEY

  # A finish whose verdict its converger owns: a classifier's decline (a
  # refusal may re-ask on the answerer's fallback; a block records its
  # stand) or an overload on every attempt (it may re-ask too).
  def converger_decides? = declined? || overloaded?

  # Until that converger records the terminal, no follower reads the
  # failure as settled: the switch would retract it.
  def undecided? = converger_decides? && terminal_event_recorded_at.nil?

  # Deliberately broader than a provider-specific signature error: silencing
  # optional replay prevents one refused native item from failing every turn.
  def replay_refused?
    return false unless failed? && REPLAY_REFUSAL_KEYS.include?(failure_reason_key)

    content_bodies.find_by(role: "request")&.native_reasoning? || false
  end

  # Completion already knows its owner. The precise wake shares the periodic
  # converger's writer; a lost enqueue is still recovered from durable state.
  def converge_owner_later
    options = { "invocation_id" => id }
    case purpose
    when INFERENCE_REQUEST_PURPOSE
      InferenceRequests::ConvergeTerminalEventsJob.perform_later(options)
    when CONVERSATION_REPLY_PURPOSE
      Conversations::Turns::ConvergeJob.perform_later(conversation_id, options)
    when AGENT_RUN_TASK_PURPOSE
      AgentRuns::ConvergeTerminalStepsJob.perform_later(0, options)
    else
      raise "unknown invocation purpose: #{purpose}"
    end
  end

  # The terminal writer every owner shares (the cancellation kernel's guarded
  # set update is the one exception): first terminal wins, so a later owner
  # converges on what it finds. Callers hold the row lock. `detail` is the
  # provider's sentence beside the key (status, message, code, type — never a
  # raw body) or beside a declined finish, bounded like a node's error_detail.
  def terminalize(status:, reason_key: nil, detail: nil, finish_quality: nil, refusal_category: nil, at: nil)
    return false if terminal?

    now = at || DatabaseClock.now
    # `canceled` owes the write-once cancellation pair from every cancel
    # source; a `canceled` row with a null `canceled_at` is indistinguishable
    # from one never cut.
    update!(
      status: status, terminal_at: now,
      failure_reason_key: reason_key&.to_s.presence,
      failure_detail: detail&.to_s&.first(256).presence,
      finish_quality: finish_quality&.to_s.presence,
      refusal_category: refusal_category&.to_s&.first(64).presence,
      **(status.to_s == "canceled" ? { canceled_at: now } : {})
    )
    true
  end

  # The invocation namespace's own idempotency key, derived from the branch
  # owner's immutable public identity and never accepted from anyone.
  def self.internal_creation_key_for(inference_request:)
    public_id = inference_request&.public_id
    return if public_id.blank?

    "#{INFERENCE_REQUEST_PURPOSE}:#{public_id}"
  end

  # Every supported purpose uses the interactive admission class.
  def service_class = "interactive"

  # THE PROMPT CACHE KEY BY THE HOST (codex-rs client.rs prompt_cache_key
  # — a parent and its children share routing): the conversation's public
  # id when conversation-hosted (directly, or through the loop's variant),
  # else the standalone loop's; a InferenceRequest has no shared-session key.
  # Never this row's id —
  # that would defeat routing. Build sends it on the wires that route by
  # it; the codex lane's session/thread headers carry the same value.
  def prompt_cache_key
    return conversation.public_id if conversation_id.present?
    return nil if agent_run.nil?

    agent_run.conversation&.public_id || agent_run.public_id
  end

  private

    # A caller may pass both owners or neither; a mismatched pair is
    # unreachable because each derivation sets `purpose` from the owner it got.
    def exactly_one_purpose_owner
      owned = PURPOSE_OWNERS.count { |_, owner| public_send(:"#{owner}_id").present? }
      return if owned == 1

      errors.add(:base, :not_exactly_one_purpose_owner)
    end

    # InferenceRequest owns the accepted user input. This callback derives only the
    # aggregate ownership facts; the create command supplies the Invocation's
    # distinct assembled-request selection and options explicitly. The key
    # is the aggregate's own unless its owner supplied one: the fallback's
    # second execution carries its ordinal, and a forced first key would
    # collide with the declined one on the unique index.
    def derive_inference_request_branch
      if inference_request
        self.account = inference_request.account
        self.workspace = inference_request.workspace
        self.creating_user = inference_request.creating_user
        self.workload = inference_request.workload
        self.purpose = INFERENCE_REQUEST_PURPOSE
        self.internal_creation_key ||= self.class.internal_creation_key_for(inference_request: inference_request)
      end
    end

    # A conversation owns many invocations, so the caller supplies
    # `creating_user` and the per-materialization `internal_creation_key`.
    def derive_conversation_branch
      if conversation
        self.account = conversation.account
        self.workspace = conversation.workspace
        self.workload = "text_generation"
        self.purpose = CONVERSATION_REPLY_PURPOSE
      end
    end

    # A loop owns many step invocations, so the scheduler supplies
    # `creating_user` and the per-(node, generation) `internal_creation_key`.
    def derive_agent_run_branch
      if agent_run
        self.account = agent_run.account
        self.workspace = agent_run.workspace
        self.workload = "text_generation"
        self.purpose = AGENT_RUN_TASK_PURPOSE
      end
    end
end
