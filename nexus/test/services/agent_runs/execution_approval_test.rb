require "test_helper"
require_relative "../../test_helpers/agent_runs_execution_test_helper"

class AgentRuns::ExecutionApprovalTest < ActiveJob::TestCase
  include AgentRunsExecutionTestHelper

  # ── THE APPROVAL STAGE ──────────────────────────
  #
  # Under `ask` a MODEL-composed tool row parks: it
  # rests at `needs_approval` addressed to the host's agent application, on the 24 h park clock,
  # with the effect profile the approver reads, nothing dispatched — and the loop stays `running`,
  # announced `approval_required` naming the held key. Rows the append door or the kernel wrote are
  # pre-approved by their origin and never park.

  def reading_model(key, **over)
    model(key, "tools" => [RunLaneTestHelper::READ_TOOL], **over)
  end

  def start_as!(agent_run, user)
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: user))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def fan_read!(agent_run, key: "round1")
    run_step!(agent_run, sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]), key: key)
    agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
  end

  test "under ask a model-composed tool row rests at needs_approval addressed to the agent application, on the clock, announced" do
    agent = users(:agent)
    agent_run = seed(reading_model("round1"), creating_user: agent, approval_mode: "ask")
    start_as!(agent_run, agent)
    call = fan_read!(agent_run)

    assert_equal "needs_approval", call.status
    assert_equal "model", call.authored_by
    assert_equal TaskExecutor.address_for(agent).id, call.addressed_executor_id
    assert_equal "agent_application", call.addressed_role, "addressed to the approver's application, not the runner"
    assert_equal suite_runner.effect_profile_for("read_file"), call.effect_profile,
      "the decision's profile, frozen for the approver to read"
    assert_not_nil call.await_started_at, "on the park clock"
    assert_nil call.started_at, "nothing was dispatched"
    assert_nil call.approval_origin, "undecided"
    assert_nil call.claimed_at
    assert_equal call.await_started_at + AgentRunTasks::AwaitTask::MAX_HOLD, call.deadline_at

    agent_run.reload
    assert_equal "running", agent_run.status, "waiting is not halting"
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.attention_reason
    item = agent_run.conversation_event_items.where(item_type: "attention_required").order(:sequence).last
    assert_equal [call.node_key], item.payload.fetch("blocked_task_keys")
    assert_equal "queued", node(agent_run, "r1").status, "the continuation waits on the held call"
    statuses = agent_run.conversation_event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map { |row| row.payload.fetch("status") }
    assert_equal %w[waiting needs_approval], statuses, "one crossing, nothing after it"
  end

  test "under rules an ask rule parks a model-composed tool row, addressed to nobody on a Human's loop" do
    agent_run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_*", "verdict" => "ask" }])
    start!(agent_run)
    call = fan_read!(agent_run)

    assert_equal "needs_approval", call.status
    assert_nil call.addressed_executor_id, "a Human's loop: the person's member door alone"
    assert_nil call.addressed_role
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.reload.attention_reason
  end

  test "under bypass a model-composed tool row is granted by the mode and dispatched" do
    agent_run = seed(reading_model("round1"))
    start!(agent_run)
    call = fan_read!(agent_run)

    assert_equal "dispatched", call.status
    assert_equal "model", call.authored_by
    assert_equal "mode", call.approval_origin
    assert_nil call.approved_by_user_id
    assert_not_nil call.approval_decided_at
    assert_nil agent_run.reload.attention_reason
  end

  # ── THE MODE TABLE WITH RULES ──────────────────────

  test "a deny rule binds under bypass at the stage: failed approval_denied from needs_approval with the rule's reason" do
    agent_run = seed(reading_model("round1"), approval_mode: "bypass",
      approval_rules: [{ "tool" => "read_*", "verdict" => "deny", "reason" => "reads are off today" }])
    start!(agent_run)
    call = fan_read!(agent_run)

    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "reads are off today", call.error_detail
    assert_nil call.started_at, "never dispatched"
    assert_nil call.approval_origin, "a refusal by rule is no grant"
    statuses = agent_run.conversation_event_items.where(item_type: "task_status").order(:sequence)
      .select { |row| row.payload["task_key"] == call.node_key }.map { |row| row.payload.fetch("status") }
    assert_equal %w[waiting needs_approval failed], statuses, "crossed, then refused — the stage is never skipped"
    assert_equal "running", node(agent_run, "r1").status, "absorb: the continuation reads the refusal"
    assert_nil agent_run.reload.attention_reason
  end

  test "under rules an unmatched call is denied as data, never parked" do
    agent_run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "bsh", "verdict" => "allow" }])
    start!(agent_run)
    call = fan_read!(agent_run)

    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "no approval rule allows read_file", call.error_detail, "a typo is a refusal the model reads"
    assert_nil agent_run.reload.attention_reason, "nothing parked for nobody"
    assert_equal "running", node(agent_run, "r1").status
  end

  test "under rules an allow rule grants by rule, and a deny rule outranks it" do
    agent_run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }])
    start!(agent_run)
    call = fan_read!(agent_run)
    assert_equal %w[dispatched rule], call.values_at(:status, :approval_origin)

    denied = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }, { "tool" => "*", "verdict" => "deny" }])
    start!(denied)
    assert_equal %w[failed approval_denied], fan_read!(denied).values_at(:status, :error_key)
  end

  test "an allow rule under ask never parks: granted by rule" do
    agent_run = seed(reading_model("round1"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }])
    start!(agent_run)
    call = fan_read!(agent_run)

    assert_equal "dispatched", call.status
    assert_equal "rule", call.approval_origin
    assert_nil call.approved_by_user_id
    assert_nil agent_run.reload.attention_reason
  end

  test "a rule naming origin author parks an authored row under ask; one naming nobody leaves it pre-approved" do
    agent_run = seed(tool("probe", "read_file"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
    start!(agent_run)
    probe = node(agent_run, "probe")
    assert_equal "needs_approval", probe.status
    assert_equal "author", probe.authored_by
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.reload.attention_reason

    untouched = seed(tool("probe", "read_file"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask" }])
    start!(untouched)
    assert_equal %w[dispatched author], node(untouched, "probe").values_at(:status, :approval_origin)
  end

  test "an authored tool row under ask never parks: pre-approved by its author" do
    agent_run = seed(tool("probe", "read_file"), approval_mode: "ask")
    start!(agent_run)

    probe = node(agent_run, "probe")
    assert_equal "dispatched", probe.status
    assert_equal "author", probe.authored_by
    assert_equal "author", probe.approval_origin
    assert_nil probe.approved_by_user_id, "the row's authored_by already says who"
    assert_not_nil probe.approval_decided_at
    assert_equal "runner", probe.addressed_role
    assert_nil agent_run.reload.attention_reason
  end

  test "a kernel-planted tool row under ask never parks: pre-approved by the kernel" do
    agent_run = seed(model("round1"), approval_mode: "ask")
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "planted", name: "read_file", route: { "kind" => "runner" })],
      tip: AgentRuns::Tasks::Tip.seed("branch")
    ))
    assert_predicate appended, :applied?
    start!(agent_run)

    planted = node(agent_run, "planted")
    assert_equal "dispatched", planted.status
    assert_equal "kernel", planted.authored_by
    assert_equal "kernel", planted.approval_origin
    assert_nil planted.approved_by_user_id
    assert_nil agent_run.reload.attention_reason
  end
end
