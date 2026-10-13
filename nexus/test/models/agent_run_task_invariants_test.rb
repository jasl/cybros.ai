require "test_helper"

# THE CONJUNCTION INVARIANTS ARE VALIDATIONS, NOT CONVENTIONS (review
# 2026-09-08, change 4). `status` is one axis — who is being waited on —
# and every other column beside it is a second dimension that is only
# meaningful in some statuses: the claim inside `dispatched`, the park
# clock on a clocked type, the adjudication stamp on a failure, the mail
# stamp after a detached settlement. The review counted nine such
# conjunctions holding by convention alone; each is now a pure validation
# over the row's own columns, so a writer that drifts is refused at the
# write rather than discovered by the reader it confused.
class AgentRunTaskInvariantsTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 8, 12, 0, 0)
  TOKEN = "4a8f2c3e-0c42-4d0a-9c8e-0d1b7d1a2b3c".freeze

  def refused(node, attribute, kind)
    node.validate
    assert node.errors.of_kind?(attribute, kind),
      "expected #{attribute}.#{kind}; got #{node.errors.details.inspect}"
  end

  def admitted(node, attribute, kind)
    node.validate
    assert_not node.errors.of_kind?(attribute, kind), node.errors.details.inspect
  end

  def claimed(**over)
    AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      claim_token: TOKEN, claimed_at: NOW, claimed_by_executor_public_id: TOKEN, **over)
  end

  # (1) `uncertain` is the sweep's word for a CLAIMED call that expired
  # with no result — an unclaimed row expires `timed_out`, whatever its profile.
  test "uncertain is a claimed call" do
    refused AgentRunTasks::ToolTask.new(status: "uncertain", completed_at: NOW), :claimed_at, :required_for_uncertain
    admitted claimed(status: "uncertain", completed_at: NOW), :claimed_at, :required_for_uncertain
  end

  # (2) An await's park word is a function of its token: `awaiting_input`
  # is the tokenless ask a person answers, `dispatched` the rendezvous
  # whose token rode out in a receipt.
  test "an await's park word follows its token" do
    refused AgentRunTasks::AwaitTask.new(status: "awaiting_input", resolution_token: TOKEN, started_at: NOW, await_started_at: NOW),
      :resolution_token, :contradicts_status
    refused AgentRunTasks::AwaitTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW),
      :resolution_token, :contradicts_status
    admitted AgentRunTasks::AwaitTask.new(status: "awaiting_input", started_at: NOW, await_started_at: NOW),
      :resolution_token, :contradicts_status
    admitted AgentRunTasks::AwaitTask.new(status: "dispatched", resolution_token: TOKEN, started_at: NOW, await_started_at: NOW),
      :resolution_token, :contradicts_status
  end

  # (3) Mail is the kernel delivering a DETACHED answer after the reply was
  # final: a stamp on a foreground row, or on one still live, is a lie.
  test "result_delivered_at is a detached settlement's stamp" do
    refused AgentRunTasks::ModelTask.new(status: "completed", completed_at: NOW, result_delivered_at: NOW, detached: false),
      :result_delivered_at, :unmailable
    refused AgentRunTasks::ModelTask.new(status: "running", started_at: NOW, result_delivered_at: NOW, detached: true),
      :result_delivered_at, :unmailable
    admitted AgentRunTasks::ModelTask.new(status: "completed", completed_at: NOW, result_delivered_at: NOW, detached: true),
      :result_delivered_at, :unmailable
  end

  # (4) The adjudication stamp names the status it resolved: `abandoned`
  # answers a failure, `canceled` is the person's branch cancel — and
  # `absorbed` is no longer a word the column holds (change 3: derived).
  test "a failure_resolution names its status" do
    refused AgentRunTasks::ToolTask.new(status: "canceled", completed_at: NOW, failure_resolution: "abandoned"),
      :failure_resolution, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "failed", completed_at: NOW, failure_resolution: "canceled"),
      :failure_resolution, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "completed", completed_at: NOW, failure_resolution: "abandoned"),
      :failure_resolution, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "failed", completed_at: NOW, failure_resolution: "absorbed"),
      :failure_resolution, :inclusion
    admitted AgentRunTasks::ToolTask.new(status: "failed", completed_at: NOW, failure_resolution: "abandoned"),
      :failure_resolution, :contradicts_status
    admitted AgentRunTasks::ToolTask.new(status: "canceled", completed_at: NOW, failure_resolution: "canceled"),
      :failure_resolution, :contradicts_status
    assert_equal %w[abandoned canceled], AgentRunTask::FAILURE_RESOLUTIONS
  end

  # (5) The claim is one fact in three columns — the token, when, and the
  # claimant's public-id snapshot (which survives the claimant's reap) —
  # and only a tool call is ever claimed: an await's proof is its own token.
  test "the claim moves as one, and only on a tool call" do
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW, claimed_at: NOW),
      :claimed_at, :partial_claim
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW, claim_token: TOKEN),
      :claimed_at, :partial_claim
    refused AgentRunTasks::AwaitTask.new(status: "dispatched", resolution_token: TOKEN, started_at: NOW, await_started_at: NOW,
      claim_token: TOKEN, claimed_at: NOW, claimed_by_executor_public_id: TOKEN), :claimed_at, :partial_claim
    admitted claimed, :claimed_at, :partial_claim
  end

  # (6) The lifecycle stamps follow the status: nothing spent has no
  # `started_at`; started work has one and no `completed_at`; a settled
  # row has its `completed_at`.
  test "the lifecycle stamps follow the status" do
    refused AgentRunTasks::ModelTask.new(status: "queued", started_at: NOW), :started_at, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "needs_approval", completed_at: NOW), :completed_at, :contradicts_status
    refused AgentRunTasks::ModelTask.new(status: "running"), :started_at, :contradicts_status
    refused AgentRunTasks::ModelTask.new(status: "running", started_at: NOW, completed_at: NOW), :completed_at, :contradicts_status
    refused AgentRunTasks::ModelTask.new(status: "completed", started_at: NOW), :completed_at, :contradicts_status
    admitted AgentRunTasks::ModelTask.new(status: "queued"), :started_at, :contradicts_status
    admitted AgentRunTasks::ModelTask.new(status: "running", started_at: NOW), :started_at, :contradicts_status
    admitted AgentRunTasks::ModelTask.new(status: "skipped", completed_at: NOW), :completed_at, :contradicts_status
  end

  # (10) The approval fact moves as one: the origin and the time together or not at all, and a named
  # approver only under a `human|agent` grant — a mode, rule, author or kernel grant names nobody.
  test "the approval fact moves as one" do
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      approval_origin: "mode"), :approval_origin, :partial_fact
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      approval_decided_at: NOW), :approval_origin, :partial_fact
    %w[mode rule author kernel].each do |origin|
      refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
        approval_origin: origin, approval_decided_at: NOW, approved_by_user_id: 7),
        :approved_by_user, :not_a_principals_grant
      admitted AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
        approval_origin: origin, approval_decided_at: NOW), :approval_origin, :partial_fact
    end
    %w[human agent].each do |origin|
      admitted AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
        approval_origin: origin, approval_decided_at: NOW, approved_by_user_id: 7),
        :approved_by_user, :not_a_principals_grant
    end
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      approval_origin: "person", approval_decided_at: NOW), :approval_origin, :inclusion
  end

  # (11) A held row is always on the clock, and a decided row never
  # rests: `needs_approval` carries `await_started_at` and no fact.
  test "the hold sits on the stage: clocked and undecided" do
    refused AgentRunTasks::ToolTask.new(status: "needs_approval"), :await_started_at, :blank
    refused AgentRunTasks::ToolTask.new(status: "needs_approval", await_started_at: NOW,
      approval_origin: "human", approval_decided_at: NOW, approved_by_user_id: 7),
      :approval_origin, :contradicts_status
    admitted AgentRunTasks::ToolTask.new(status: "needs_approval", await_started_at: NOW),
      :await_started_at, :blank
    admitted AgentRunTasks::ToolTask.new(status: "needs_approval", await_started_at: NOW),
      :approval_origin, :contradicts_status
  end

  # WHO WROTE THE ROW is a closed word every row carries.
  test "authored_by is one of the three writers" do
    refused AgentRunTasks::ModelTask.new(status: "queued"), :authored_by, :inclusion
    refused AgentRunTasks::ModelTask.new(status: "queued", authored_by: "person"), :authored_by, :inclusion
    AgentRunTask::AUTHORS.each do |author|
      admitted AgentRunTasks::ModelTask.new(status: "queued", authored_by: author), :authored_by, :inclusion
    end
  end

  # (7) The address is a generation's fact, written at the row's start
  # and cleared by a person's retry: a `queued` row names nobody, and an
  # executor id never rides without its role.
  test "the address is a generation's fact" do
    refused AgentRunTasks::ToolTask.new(status: "queued", addressed_role: "tool_provider"),
      :addressed_role, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      addressed_executor_id: 7), :addressed_role, :blank
    admitted AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW,
      addressed_role: "tool_provider"), :addressed_role, :contradicts_status
  end

  # (8) The park clock is a clocked type's alone, and a row resting with a
  # holder outside the kernel is always on it — the sweep's frontier reads
  # exactly this pair.
  test "a park clock only on a clocked type, and always under a holder word" do
    refused AgentRunTasks::ModelTask.new(status: "running", started_at: NOW, await_started_at: NOW),
      :await_started_at, :unclocked
    refused AgentRunTasks::JoinTask.new(status: "queued", await_started_at: NOW), :await_started_at, :unclocked
    refused AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW), :await_started_at, :blank
    refused AgentRunTasks::AwaitTask.new(status: "awaiting_input", started_at: NOW), :await_started_at, :blank
    admitted AgentRunTasks::ToolTask.new(status: "dispatched", started_at: NOW, await_started_at: NOW),
      :await_started_at, :blank
  end

  # (9) Three columns that belong to one kind or one outcome: an error key
  # rides a failure or a cancel, an invocation rides a round, a resolution
  # token rides an await.
  test "the error key, the invocation and the resolution token follow the kind" do
    refused AgentRunTasks::ToolTask.new(status: "completed", completed_at: NOW, error_key: "x"),
      :error_key, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "skipped", completed_at: NOW, error_key: "x"),
      :error_key, :contradicts_status
    admitted AgentRunTasks::ToolTask.new(status: "canceled", completed_at: NOW, error_key: "run_canceled"),
      :error_key, :contradicts_status
    refused AgentRunTasks::ToolTask.new(status: "running", started_at: NOW, await_started_at: NOW,
      selected_model_invocation_id: 3), :selected_model_invocation, :not_a_round
    admitted AgentRunTasks::ModelTask.new(status: "running", started_at: NOW, selected_model_invocation_id: 3),
      :selected_model_invocation, :not_a_round
    refused AgentRunTasks::ToolTask.new(status: "queued", resolution_token: TOKEN), :resolution_token, :not_an_await
    admitted AgentRunTasks::AwaitTask.new(status: "queued", resolution_token: TOKEN), :resolution_token, :not_an_await
  end
end
