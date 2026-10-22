require "test_helper"
require_relative "../../test_helpers/runs_execution_test_helper"

class Runs::ExecutionApprovalTest < ActiveJob::TestCase
  include RunsExecutionTestHelper

  # ── THE APPROVAL STAGE ──────────────────────────
  #
  # Under `ask` a MODEL-composed tool row parks: it
  # rests at `needs_approval` addressed to the host's agent, on the 24 h park clock,
  # with the effect profile the approver reads, nothing dispatched — and the loop stays `running`,
  # announced `approval_required` naming the held key. Rows the append door or the kernel wrote are
  # pre-approved by their origin and never park.

  def reading_model(key, **over)
    model(key, "tools" => [RunLaneTestHelper::READ_TOOL], **over)
  end

  def start_as!(run, user)
    result = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: user))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    schedule!(run)
  end

  def fan_read!(run, key: "round1")
    run_step!(run, sse_success("reading", tool_calls: [
      { id: "call_read", name: "read_file", arguments: "{}" },
    ]), key: key)
    run.tasks.find_by!(tool_call_id: "call_read")
  end

  test "under ask a model-composed tool row rests at needs_approval addressed to the agent, on the clock, announced" do
    agent = users(:agent)
    run = seed(reading_model("round1"), creating_user: agent, approval_mode: "ask")
    start_as!(run, agent)
    call = fan_read!(run)

    assert_equal "needs_approval", call.status
    assert_equal "model", call.authored_by
    assert_equal Executor.address_for(agent).id, call.addressed_executor_id
    assert_equal "agent", call.addressed_role, "addressed to the approver's application, not the runner"
    assert_equal suite_runner.effect_profile_for("read_file", role: suite_runner.executor_kind), call.effect_profile,
      "the decision's profile, frozen for the approver to read"
    assert_not_nil call.await_started_at, "on the park clock"
    assert_nil call.started_at, "nothing was dispatched"
    assert_nil call.approval_origin, "undecided"
    assert_nil call.claimed_at
    assert_equal call.await_started_at + Tasks::AwaitTask::MAX_HOLD, call.deadline_at

    run.reload
    assert_equal "running", run.status, "waiting is not halting"
    assert_equal Runs::EvaluateQuiescence::APPROVAL_REASON, run.attention_reason
    item = run.event_items.where(item_type: "attention_required").order(:sequence).last
    assert_equal [call.node_key], item.payload.fetch("blocked_task_keys")
    assert_equal "queued", node(run, "r1").status, "the continuation waits on the held call"
    statuses = run.event_items.where(item_type: "task_status")
      .select { |row| row.payload["task_key"] == call.node_key }.map { |row| row.payload.fetch("status") }
    assert_equal %w[waiting needs_approval], statuses, "one crossing, nothing after it"
  end

  test "under rules an ask rule parks a model-composed tool row, addressed to nobody on a Human's loop" do
    run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_*", "verdict" => "ask" }])
    start!(run)
    call = fan_read!(run)

    assert_equal "needs_approval", call.status
    assert_nil call.addressed_executor_id, "a Human's loop: the person's member door alone"
    assert_nil call.addressed_role
    assert_equal Runs::EvaluateQuiescence::APPROVAL_REASON, run.reload.attention_reason
  end

  test "under bypass a model-composed tool row is granted by the mode and dispatched" do
    run = seed(reading_model("round1"))
    start!(run)
    call = fan_read!(run)

    assert_equal "dispatched", call.status
    assert_equal "model", call.authored_by
    assert_equal "mode", call.approval_origin
    assert_nil call.approved_by_user_id
    assert_not_nil call.approval_decided_at
    assert_nil run.reload.attention_reason
  end

  # ── THE MODE TABLE WITH RULES ──────────────────────

  test "a deny rule binds under bypass at the stage: failed approval_denied from needs_approval with the rule's reason" do
    run = seed(reading_model("round1"), approval_mode: "bypass",
      approval_rules: [{ "tool" => "read_*", "verdict" => "deny", "reason" => "reads are off today" }])
    start!(run)
    call = fan_read!(run)

    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "reads are off today", call.error_detail
    assert_nil call.started_at, "never dispatched"
    assert_nil call.approval_origin, "a refusal by rule is no grant"
    statuses = run.event_items.where(item_type: "task_status").order(:sequence)
      .select { |row| row.payload["task_key"] == call.node_key }.map { |row| row.payload.fetch("status") }
    assert_equal %w[waiting needs_approval failed], statuses, "crossed, then refused — the stage is never skipped"
    assert_equal "running", node(run, "r1").status, "absorb: the continuation reads the refusal"
    assert_nil run.reload.attention_reason
  end

  test "under rules an unmatched call is denied as data, never parked" do
    run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "bsh", "verdict" => "allow" }])
    start!(run)
    call = fan_read!(run)

    assert_equal %w[failed approval_denied], call.values_at(:status, :error_key)
    assert_equal "no approval rule allows read_file", call.error_detail, "a typo is a refusal the model reads"
    assert_nil run.reload.attention_reason, "nothing parked for nobody"
    assert_equal "running", node(run, "r1").status
  end

  test "under rules an allow rule grants by rule, and a deny rule outranks it" do
    run = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }])
    start!(run)
    call = fan_read!(run)
    assert_equal %w[dispatched rule], call.values_at(:status, :approval_origin)

    denied = seed(reading_model("round1"), approval_mode: "rules",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }, { "tool" => "*", "verdict" => "deny" }])
    start!(denied)
    assert_equal %w[failed approval_denied], fan_read!(denied).values_at(:status, :error_key)
  end

  test "an allow rule under ask never parks: granted by rule" do
    run = seed(reading_model("round1"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "allow" }])
    start!(run)
    call = fan_read!(run)

    assert_equal "dispatched", call.status
    assert_equal "rule", call.approval_origin
    assert_nil call.approved_by_user_id
    assert_nil run.reload.attention_reason
  end

  test "an explicit Runner callable rule selects one of two Runners serving the same tool" do
    calls = fan_runner_aliases!([{ "tool" => "local_read", "verdict" => "allow" }])

    assert_equal %w[read_file local_read], calls.first.values_at(:tool_name, :tool_alias)
    assert_equal %w[read_file remote_read], calls.last.values_at(:tool_name, :tool_alias)
    assert_equal 2, calls.map(&:target_executor_public_id).uniq.length
    assert_equal %w[dispatched rule], calls.first.values_at(:status, :approval_origin)
    assert_equal %w[failed approval_denied], calls.last.values_at(:status, :error_key)
    assert_nil calls.last.started_at
  end

  test "a Runner callable denial overrides a served-name allow without denying the other Runner" do
    calls = fan_runner_aliases!([
      { "tool" => "read_file", "verdict" => "allow" },
      { "tool" => "local_read", "verdict" => "deny", "reason" => "local reads are disabled" },
    ])

    assert_equal %w[failed approval_denied], calls.first.values_at(:status, :error_key)
    assert_equal "local reads are disabled", calls.first.error_detail
    assert_nil calls.first.started_at
    assert_equal %w[dispatched rule], calls.last.values_at(:status, :approval_origin)
  end

  test "a rule naming origin author parks an authored row under ask; one naming nobody leaves it pre-approved" do
    run = seed(tool("probe", "read_file"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
    start!(run)
    probe = node(run, "probe")
    assert_equal "needs_approval", probe.status
    assert_equal "author", probe.authored_by
    assert_equal Runs::EvaluateQuiescence::APPROVAL_REASON, run.reload.attention_reason

    untouched = seed(tool("probe", "read_file"), approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask" }])
    start!(untouched)
    assert_equal %w[dispatched author], node(untouched, "probe").values_at(:status, :approval_origin)
  end

  test "an authored tool row under ask never parks: pre-approved by its author" do
    run = seed(tool("probe", "read_file"), approval_mode: "ask")
    start!(run)

    probe = node(run, "probe")
    assert_equal "dispatched", probe.status
    assert_equal "author", probe.authored_by
    assert_equal "author", probe.approval_origin
    assert_nil probe.approved_by_user_id, "the row's authored_by already says who"
    assert_not_nil probe.approval_decided_at
    assert_equal "runner", probe.addressed_role
    assert_nil run.reload.attention_reason
  end

  test "a kernel-planted tool row under ask never parks: pre-approved by the kernel" do
    run = seed(model("round1"), approval_mode: "ask")
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, origin: "kernel",
      steps: [Runs::Tasks::Step::Tool.new(key: "planted", name: "read_file", route: { "kind" => "runner" })],
      tip: Runs::Tasks::Tip.seed("branch")
    ))
    assert_predicate appended, :applied?
    start!(run)

    planted = node(run, "planted")
    assert_equal "dispatched", planted.status
    assert_equal "kernel", planted.authored_by
    assert_equal "kernel", planted.approval_origin
    assert_nil planted.approved_by_user_id
    assert_nil run.reload.attention_reason
  end

  private

    def fan_runner_aliases!(rules)
      remote = connect_runner(manager: users(:owner), registration_identifier: "approval-remote",
        display_name: "Remote reads", assignment_scope: :account_wide).executor_access_token.executor
      assert_predicate remote.announce(services: { remote.executor_kind => { "tools" => RunAuthoringTestHelper::TEST_SERVED_TOOLS } }), :accepted?
      aliases = { "local_read" => suite_runner, "remote_read" => remote }
      tools = aliases.map do |name, runner|
        RunLaneTestHelper::READ_TOOL.merge(
          "function" => RunLaneTestHelper::READ_TOOL.fetch("function").merge("name" => name),
          "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => "read_file" })
      end
      run = seed(model("round1", "tools" => tools), approval_mode: "rules", approval_rules: rules)
      start!(run)
      run_step!(run, sse_success("Read both Runners", tool_calls: aliases.keys.map do |name|
        { id: "call_#{name}", name: name, arguments: "{}" }
      end), key: "round1")
      aliases.keys.map { |name| run.tasks.find_by!(tool_call_id: "call_#{name}") }
    end
end
