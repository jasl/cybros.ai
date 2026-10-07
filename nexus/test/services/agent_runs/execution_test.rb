require "test_helper"

# model execution and failure containment, through the REAL chain: start → schedule → step
# invocation → real admission → the real start/build/dispatch path against the fake adapter →
# terminal apply → the step converger → the release walk → quiescence. Only the HTTP adapter is
# faked (the harness's charter).
class AgentRuns::ExecutionTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(agent_run)
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  # Admission admits EVERYTHING queued at once, so a parallel fan's
  # attempts all arrive in one pass — cache them and answer per node
  # (matched through the node's own invocation pointer, never by luck).
  def step_attempt(agent_run, key: nil)
    @admitted_attempts ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted_attempts[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    node = key ? node(agent_run, key) : running_model_node(agent_run)
    @admitted_attempts.fetch(node.selected_model_invocation_id) do
      raise "step not admitted for #{node.node_key}"
    end
  end

  def running_model_node(agent_run)
    agent_run.agent_run_tasks
      .where(status: "running").where.not(selected_model_invocation_id: nil).sole
  end

  # One full step: admit the queued step invocation, run it against the
  # fake adapter, converge the terminal, wake the scheduler.
  def run_step!(agent_run, behaviour, key: nil)
    apply_via(step_attempt(agent_run, key: key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  test "the happy path: two chained model tasks, answers adopted, loop completes" do
    agent_run = seed(model("plan", "prompt" => "make a plan"), model("write", "prompt" => "write it"))
    start!(agent_run)

    plan = node(agent_run, "plan")
    assert_equal "running", plan.status
    invocation = ModelInvocation.find(plan.selected_model_invocation_id)
    assert_equal "agent_run_task", invocation.purpose
    assert_equal "interactive", invocation.service_class
    assert_equal "agent_run_task:#{plan.id}:0", invocation.internal_creation_key
    assert_equal 3, ModelInvocations::AttemptOrdinal::BUDGETS.fetch("agent_run_task")
    request = invocation.content_bodies.find_by!(role: "request")
    assert_equal "make a plan",
      request.content_body_entries.sole.content_fragment.payload.dig("parts", 0, "text")
    assert_equal "queued", node(agent_run, "write").status

    run_step!(agent_run, sse_success("the plan"))
    plan.reload
    assert_equal "completed", plan.status
    assert_includes plan.content_bodies.find_by!(role: "output").effective_text, "the plan"
    assert_includes AgentAPI::AgentRunPresenter.task_detail(plan)[:output], "the plan",
      "the single-task read carries the full answer — the deliverable retrieval path"
    assert_equal "running", node(agent_run, "write").status,
      "the release walk freed the dependent and the scheduler started it"

    run_step!(agent_run, sse_success("the essay"))
    assert_equal "completed", node(agent_run, "write").status
    agent_run.reload
    assert_equal "completed", agent_run.status, "last sink completed = deliverable answered"
    assert_not_nil agent_run.completed_at
  end

  test "a failed step auto-retries under a fresh generation while the budget lasts" do
    agent_run = seed(model("flaky", "retry" => 1))
    start!(agent_run)
    flaky = node(agent_run, "flaky")
    first_invocation_id = flaky.selected_model_invocation_id

    apply_via(step_attempt(agent_run), json_response(400, { "error" => "bad" }))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    flaky.reload
    assert_equal "queued", flaky.status, "the budget covers one automatic retry"
    assert_equal 1, flaky.execution_generation

    schedule!(agent_run)
    flaky.reload
    assert_equal "running", flaky.status
    assert_not_equal first_invocation_id, flaky.selected_model_invocation_id
    assert_equal "agent_run_task:#{flaky.id}:1",
      ModelInvocation.find(flaky.selected_model_invocation_id).internal_creation_key

    run_step!(agent_run, sse_success("second try"))
    assert_equal "completed", node(agent_run, "flaky").status
    assert_equal "completed", agent_run.reload.status
  end

  test "an exhausted halt failure holds the loop, and the retry verb is the exit" do
    agent_run = seed(model("brittle"))
    start!(agent_run)

    run_step!(agent_run, json_response(400, { "error" => {
      "message" => "Kimi K3 tool messages need a preceding assistant tool call",
      "code" => 400, "type" => "invalid_request_error",
    } }))
    brittle = node(agent_run, "brittle")
    assert_equal "failed", brittle.status
    assert_equal "provider_http_error", brittle.error_key
    # What the provider answered, on the node: the status and its sentence, never the raw body.
    assert_equal "HTTP 400: Kimi K3 tool messages need a preceding assistant tool call " \
      "(400, invalid_request_error)", brittle.error_detail
    assert_nil brittle.failure_resolution, "halt = unresolved, awaiting adjudication"
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "halt_failure", agent_run.attention_reason

    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "brittle", acting_user: @human
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "running", agent_run.status
    assert_nil agent_run.attention_reason
    brittle.reload
    assert_equal "queued", brittle.status
    assert_equal 1, brittle.execution_generation
    assert_nil brittle.error_key

    clear_enqueued_jobs
    schedule!(agent_run)
    run_step!(agent_run, sse_success("repaired"))
    assert_equal "completed", agent_run.reload.status
  end

  test "abandon resolves a halt failure: dependents proceed, quiescence judges the deliverable" do
    agent_run = seed(model("risky"), model("summary", "prompt" => "sum up"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    assert_equal "needs_attention", agent_run.reload.status

    result = nil
    # Work remains (the dependent is queued at countdown zero), so the
    # in-lock judgement leaves the loop running and the scheduler is woken.
    assert_enqueued_with(job: AgentRuns::ScheduleJob, args: [agent_run.id]) do
      result = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
        agent_run: agent_run, task_key: "risky", acting_user: @human
      ))
    end
    assert_predicate result, :accepted?
    assert_equal "abandoned", node(agent_run, "risky").failure_resolution
    assert_equal "running", agent_run.reload.status
    assert_nil agent_run.attention_reason

    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "summary").status,
      "abandoned is a resolved settlement — the plain dependent runs"
    run_step!(agent_run, sse_success("summed"))
    assert_equal "completed", agent_run.reload.status
  end

  # The abandon judges quiescence under the lock it already holds, so the
  # loop's committed state is its final one: an abandoned sole deliverable
  # re-holds INSIDE the abandon's commit — never a transient `running` the
  # conversation converger (woken after commit, before any scheduler pass)
  # could reopen the hold-settled turn on.
  test "abandoning the sole deliverable holds deliverable_unresolved in the abandon's own commit, with nothing to schedule" do
    agent_run = seed(model("only"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "halt_failure", agent_run.attention_reason
    before = agent_run.conversation_event_items.maximum(:sequence)

    result = nil
    assert_no_enqueued_jobs(only: AgentRuns::ScheduleJob) do
      result = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
        agent_run: agent_run, task_key: "only", acting_user: @human
      ))
    end
    assert_predicate result, :accepted?
    assert_equal "abandoned", node(agent_run, "only").failure_resolution
    agent_run.reload
    assert_equal "needs_attention", agent_run.status, "no job ran: the state is the commit's"
    assert_equal "deliverable_unresolved", agent_run.attention_reason,
      "the deliverable was abandoned, not answered — the kernel never synthesizes"

    # The feed keeps the truth of each write, in the one envelope: the
    # release to running and the re-hold, then the hold announced.
    items = agent_run.conversation_event_items.after_sequence(before).order(:sequence)
    assert_equal %w[task_status turn_status turn_status attention_required], items.map(&:item_type)
    assert_equal "abandoned", items.first.payload.fetch("failure_resolution")
    assert_equal %w[running needs_attention],
      items.select { |item| item.item_type == "turn_status" }.map { |item| item.payload.fetch("run_status") }
    assert_equal "deliverable_unresolved", items.last.payload.fetch("reason")
    assert_empty items.last.payload.fetch("blocked_task_keys"),
      "an abandoned failure is resolved: nothing is left to adjudicate"

    schedule!(agent_run)
    assert_equal "deliverable_unresolved", agent_run.reload.attention_reason,
      "a later scheduler pass is level-triggered and changes nothing"
  end

  test "propagate cascades a live skip through descendants and quiescence answers honestly" do
    agent_run = seed(model("gate", "on_failure" => "propagate"), model("mid"), model("last"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))

    assert_equal "failed", node(agent_run, "gate").status
    assert_equal "skipped", node(agent_run, "mid").status
    assert_equal "skipped", node(agent_run, "last").status,
      "the skip cascade is transitive through the live release walk"
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "deliverable_unresolved", agent_run.attention_reason,
      "a resolved graph with no completed deliverable never synthesizes an answer"
  end

  test "absorb resolves in the failing write and the dependent still runs" do
    agent_run = seed(model("optional", "on_failure" => "absorb"), model("main", "prompt" => "carry on"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))

    optional = node(agent_run, "optional")
    assert_equal "failed", optional.status
    assert_nil optional.failure_resolution, "absorb is the policy's settlement, never a stamp"
    assert_equal :resolved, AgentRuns::Graph.settlement_of(optional)
    assert_equal "running", node(agent_run, "main").status

    run_step!(agent_run, sse_success("done anyway"))
    assert_equal "completed", agent_run.reload.status
  end

  test "a tool task parks on its runner, with its own clock" do
    agent_run = seed(tool("probe"))
    start!(agent_run)

    probe = node(agent_run, "probe")
    assert_equal "dispatched", probe.status,
      "the kernel hands the call out and waits - the same park an await takes"
    assert_not_nil probe.await_started_at, "and it carries a clock"
    assert_equal "running", agent_run.reload.status

    settled = AgentRuns::Parks::Settle.call(
      node: probe, trusted: true, content: "42", outcome: "completed"
    )
    assert_predicate settled, :applied?
    assert_equal "completed", node(agent_run, "probe").status
  end

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

  test "a model step after a round composes its history, and its own input closes the request" do
    agent_run = seed(model("src", "prompt" => "the original question"),
      model("consumer", "prompt" => "and now summarize"))
    start!(agent_run)
    run_step!(agent_run, sse_success("source output"))

    consumer = node(agent_run, "consumer")
    assert_equal "running", consumer.status
    texts = ModelInvocation.find(consumer.selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_equal ["the original question", "Mock: source output", "and now summarize"],
      texts, "the source's sealed input verbatim, then its answer, then this " \
        "task's own question - the prefix extends"
  end

  test "a splice whose last word would be the assistant's is refused, not sent" do
    agent_run = seed(model("src", "prompt" => "q"))
    start!(agent_run)
    # Only a kernel author places a promptless round. A mainline-marked one
    # reading a single source is the plant's shape and skips, and any
    # unpaired source is delivered in an envelope, so the shape with
    # nothing after the assistant's word is a promptless BRANCH reading
    # the mainline alone.
    src = node(agent_run, "src")
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel",
      steps: [AgentRuns::Tasks::Step.inheriting(src, key: "consumer")],
      tip: kernel_tip(src, [src], [], "branch")
    ))
    assert_predicate appended, :applied?
    run_step!(agent_run, sse_success("answer"), key: "src")
    schedule!(agent_run)

    consumer = node(agent_run, "consumer")
    assert_equal "failed", consumer.status
    assert_equal "missing_input", consumer.error_key,
      "the source made no tool calls and this step has no prompt, so nothing " \
        "follows the assistant's answer - one wire refuses that pre-IO and the " \
        "rest answer nothing useful. The kernel's own continuation always " \
        "closes with tool results, so this reaches only a hand-authored splice."
  end

  test "two-phase cancel: in-flight steps terminalize, the drain settles the loop" do
    agent_run = seed(model("running-step"), model("waiting-step"))
    start!(agent_run)
    running = node(agent_run, "running-step")
    invocation = ModelInvocation.find(running.selected_model_invocation_id)

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_equal "canceled", node(agent_run, "waiting-step").status
    assert_equal "canceled", invocation.reload.status
    assert_equal "running", running.reload.status,
      "phase one never touches a running node — the converger applies its terminal"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", running.reload.status
    assert_equal "canceled", agent_run.reload.status
  end

  test "pause stops scheduling while in-flight work still applies; resume picks it up" do
    agent_run = seed(model("first"), model("second"))
    start!(agent_run)

    pause = AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate pause, :accepted?

    apply_via(step_attempt(agent_run), sse_success("landed while paused"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "completed", node(agent_run, "first").status,
      "pause stops scheduling, never result application"
    assert_equal "queued", node(agent_run, "second").status

    resume = AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate resume, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "second").status
  end

  test "a barrier's halt failure is picked up at quiescence (the S1 obligation)" do
    agent_run = seed(model("mainline"),
      parallel(tool("a", "on_failure" => "propagate"), tool("b", "on_failure" => "propagate"),
        until: "any", key: "race", on_failure: "halt"),
      model("after"))
    start!(agent_run)
    run_step!(agent_run, sse_success("mainline done"), key: "mainline")
    assert_equal %w[dispatched dispatched], %w[a b].map { |key| node(agent_run, key).status }

    %w[a b].each do |key|
      AgentRuns::Parks::Settle.call(node: node(agent_run, key), trusted: true,
        content: "could not", outcome: "failed")
    end
    race = node(agent_run, "race")
    assert_equal "failed", race.status, "starved: every member settled without a success"
    assert_equal "join_starved", race.error_key
    assert_nil race.failure_resolution, "the group's halt is the barrier row's"

    schedule!(agent_run)
    agent_run.reload
    assert_equal "needs_attention", agent_run.status,
      "quiescence picks up the barrier's unresolved failure"
    assert_equal "halt_failure", agent_run.attention_reason
    assert_equal "queued", node(agent_run, "after").status, "the follower waits for the adjudication"
  end

  test "a superseded invocation's late result applies to nothing — settled or running" do
    agent_run = seed(model("solo", "retry" => 1))
    start!(agent_run)
    solo = node(agent_run, "solo")

    # While the node RUNS its second generation, a stale terminal that is
    # not its selected invocation must not touch it — this is the fence
    # the money path rides, checked on a running node so the status guard
    # cannot answer for it.
    apply_via(step_attempt(agent_run), json_response(400, { "error" => "bad" }))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    solo.reload
    assert_equal "running", solo.status
    assert_equal 1, solo.execution_generation

    stale = ModelInvocation.create!(
      agent_run: agent_run, creating_user: @human,
      internal_creation_key: "agent_run_task:#{solo.id}:9",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )
    stale.terminalize(status: "failed", reason_key: "provider_http_error")
    result = AgentRuns::ConvergeTerminalSteps.call
    assert_equal 1, result[:recorded]
    solo.reload
    assert_equal "running", solo.status, "the fence held on a RUNNING node"
    assert_equal 1, solo.execution_generation
    assert_not_nil stale.reload.terminal_event_recorded_at

    # And a settled node ignores spurious terminals the same way.
    run_step!(agent_run, sse_success("the answer"))
    assert_equal "completed", solo.reload.status
    late = ModelInvocation.create!(
      agent_run: agent_run, creating_user: @human,
      internal_creation_key: "agent_run_task:#{solo.id}:12",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )
    late.terminalize(status: "failed", reason_key: "provider_http_error")
    AgentRuns::ConvergeTerminalSteps.call
    assert_equal "completed", solo.reload.status
    assert_not_nil late.reload.terminal_event_recorded_at
  end

  test "the schedule sweep re-seeds a loop whose wake was lost" do
    agent_run = seed(model("orphan"))
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    assert_equal "queued", node(agent_run, "orphan").status, "the wake was never run"

    AgentRuns::ScheduleSweepJob.perform_now
    assert_equal "running", node(agent_run, "orphan").status
  end

  test "the ask waits indefinitely — no sweep ends a hold (§9c)" do
    agent_run = seed(model("brittle"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    agent_run.reload
    assert_equal "needs_attention", agent_run.status

    # Days pass; nothing expires the ask — the exits are the adjudication verbs, stop, and
    # tombstone, never a clock.
    assert_not defined?(AgentRuns::AttentionSweepJob),
      "the attention sweep is deleted, not merely disabled"
    assert_equal "needs_attention", agent_run.reload.status
    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "brittle", acting_user: @human
    ))
    assert_predicate result, :accepted?, "the three-day-old ask is still answerable"
    assert_equal "running", agent_run.reload.status
  end

  test "the drain sweep escalates a canceling loop past the hard limit" do
    agent_run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    start!(agent_run)
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", agent_run.reload.status

    AgentRuns::DrainSweepJob.perform_now
    assert_equal "canceling", agent_run.reload.status,
      "a young drain re-evaluates and keeps waiting for its park"

    # Past the ceiling nothing legitimate can still be pending — whatever
    # remains is a bug's residue, and the sweep bounds what it costs.
    agent_run.update_columns(canceling_since: 25.hours.ago)
    AgentRuns::DrainSweepJob.perform_now
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "gate").status
  end

  test "a live any-join settles on the first success and its outcomes speak the trace vocabulary" do
    agent_run = seed(
      parallel(model("fast"), [model("slow"), model("late")], until: "any", key: "race", losers: "run_out"),
      model("after", "prompt" => "go on")
    )
    start!(agent_run)

    run_step!(agent_run, sse_success("fast wins"), key: "fast")
    race = node(agent_run, "race")
    assert_equal "completed", race.status, "the any-join settled live, mid-run"
    assert_equal({ "fast" => "completed", "late" => "waiting" },
      race.output_summary["outcomes"],
      "a pending sibling renders as `waiting` — the engine's `queued` never leaks")
    assert_equal "running", node(agent_run, "after").status

    run_step!(agent_run, sse_success("after done"), key: "after")
    run_step!(agent_run, sse_success("slow done"), key: "slow")
    run_step!(agent_run, sse_success("late done"), key: "late")
    assert_equal "completed", agent_run.reload.status
  end

  # A loser of a race that already settled is absorbed by that settlement — the question was
  # answered, so its later halt-failure cannot park the loop on it.
  test "a loser that fails after its any-join settled is absorbed, and the loop completes" do
    agent_run = seed(
      parallel(model("fast"), model("late"), until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start!(agent_run)
    run_step!(agent_run, sse_success("fast wins"), key: "fast")
    assert_equal "completed", node(agent_run, "race").status

    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "late")
    late = node(agent_run, "late")
    assert_equal "failed", late.status
    assert_nil late.failure_resolution, "nobody adjudicated it"
    assert_equal "halt", late.on_failure
    assert_equal :resolved, AgentRuns::Graph.settlement_of(late),
      "every edge out of the loser leads to a race that already settled"

    run_step!(agent_run, sse_success("after done"), key: "after")
    agent_run.reload
    assert_equal "completed", agent_run.status, "an answered race holds nothing"
    assert_nil agent_run.attention_reason
  end

  test "a loser that failed before its any-join settled is absorbed once the race is answered" do
    agent_run = seed(
      parallel(model("fast"), model("late"), until: "any", key: "race", losers: "run_out"),
      model("after")
    )
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "late")
    assert_equal "failed", node(agent_run, "late").status
    assert_equal "queued", node(agent_run, "race").status, "the race is still open"
    assert_equal :pending, AgentRuns::Graph.settlement_of(node(agent_run, "late")),
      "an open race cannot absorb: the loser may yet be the only answer"
    assert_equal "running", node(agent_run, "fast").status, "a running sibling means no hold yet"

    run_step!(agent_run, sse_success("fast wins"), key: "fast")
    assert_equal "completed", node(agent_run, "race").status
    assert_equal :resolved, AgentRuns::Graph.settlement_of(node(agent_run, "late"))

    run_step!(agent_run, sse_success("after done"), key: "after")
    agent_run.reload
    assert_equal "completed", agent_run.status
    assert_nil agent_run.attention_reason
  end

  test "a halt failure whose edge leads to a plain task or an all-barrier still holds" do
    agent_run = seed(model("brittle"), model("after"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    assert_equal :pending, AgentRuns::Graph.settlement_of(node(agent_run, "brittle")),
      "a plain consumer downstream is no settled race"
    assert_equal "halt_failure", agent_run.reload.attention_reason

    agent_run = seed(parallel(model("a"), model("b"), until: "all"), model("after"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "a")
    run_step!(agent_run, sse_success("b done"), key: "b")
    assert_equal "queued", node(agent_run, "after").status, "an all-wait waits for the adjudication"
    assert_equal :pending, AgentRuns::Graph.settlement_of(node(agent_run, "a")),
      "an all-wait places no race, so nothing absorbs its member"
    assert_equal "halt_failure", agent_run.reload.attention_reason
  end

  test "a live quorum join fails unreachable the moment the count is knowable" do
    agent_run = seed(
      parallel([model("x", "on_failure" => "propagate"), model("y")], model("z"), until: 2, key: "q"),
      model("after")
    )
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "x")

    q = node(agent_run, "q")
    assert_equal "failed", q.status
    assert_equal "quorum_unreachable", q.error_key,
      "a live join failure carries the same typed key a born failure does"
  end

  test "retry refuses a failed join; abandon resolves it" do
    agent_run = seed(
      parallel(model("doomed", "on_failure" => "propagate"), until: "any", key: "dead-join", on_failure: "halt"),
      model("after")
    )
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))

    dead_join = node(agent_run, "dead-join")
    assert_equal "failed", dead_join.status
    assert_equal "join_starved", dead_join.error_key,
      "a starved race carries its typed key"

    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "dead-join", acting_user: @human
    ))
    assert_equal :not_retryable, retried.outcome,
      "a join has no execution to re-run — the formula's verdict is not retryable"
    assert_equal "failed", dead_join.reload.status

    abandoned = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
      agent_run: agent_run, task_key: "dead-join", acting_user: @human
    ))
    assert_predicate abandoned, :accepted?
    assert_equal "abandoned", dead_join.reload.failure_resolution
  end

  test "an applied append releases the attention hold, and quiescence re-holds" do
    # The hold's cause is a fan member, not the tip: an append past an
    # unresolved TIP is refused (`tip_unresolved`), and adjudication is its exit.
    agent_run = seed(parallel(model("brittle"), model("fine")), model("answer"))
    start!(agent_run)
    run_step!(agent_run, sse_success("fine"), key: "fine")
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "brittle")
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "queued", node(agent_run, "answer").status

    appended = grow(agent_run, tool("probe"))
    assert_predicate appended, :applied?, "a tool hangs below the waiting answer"
    agent_run.reload
    assert_equal "running", agent_run.status, "append is the designed repair exit"
    assert_nil agent_run.attention_reason

    clear_enqueued_jobs
    schedule!(agent_run)
    agent_run.reload
    assert_equal "needs_attention", agent_run.status,
      "the original halt failure is still unresolved — quiescence re-holds"
    assert_equal "halt_failure", agent_run.attention_reason,
      "the re-hold names its reason; no clock rides it"
  end

  test "a step that fails while the loop is canceling settles canceled, never requeued" do
    agent_run = seed(model("racy", "retry" => 3))
    start!(agent_run)
    racy = node(agent_run, "racy")
    invocation = ModelInvocation.find(racy.selected_model_invocation_id)
    # The race: the step self-terminalizes (deadline sweep / attempt budget)
    # before cancel's phase one runs, so cancel's own terminalize no-ops.
    ModelInvocation.lock.find(invocation.id)
      .terminalize(status: "failed", reason_key: "attempt_budget_spent")

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "canceling", agent_run.reload.status

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    racy.reload
    assert_equal "canceled", racy.status,
      "the retry budget never resurrects work inside a dying loop"
    assert_equal "canceled", agent_run.reload.status
  end

  test "a graceful stop lets in-flight work finish and KEEPS its answer" do
    agent_run = seed(model("working", "prompt" => "almost done"), model("waiting"))
    start!(agent_run)
    working = node(agent_run, "working")
    invocation = ModelInvocation.find(working.selected_model_invocation_id)

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_equal "canceled", node(agent_run, "waiting").status,
      "nothing NEW ever starts, graceful or not"
    assert_equal "queued", invocation.reload.status,
      "the in-flight step was NOT terminalized — graceful means finish"

    run_step!(agent_run, sse_success("the last answer"))
    working.reload
    assert_equal "completed", working.status
    assert_includes working.content_bodies.find_by!(role: "output").effective_text,
      "the last answer", "the drain waited and the answer survived"
    assert_equal "canceled", agent_run.reload.status
  end

  test "a graceful stop waits for a parked await, which can still resolve" do
    agent_run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    token = AgentRunAppendReceipt.where(agent_run_id: agent_run.id).order(:id).first
      .response_body.dig("resolution_tokens", "gate")
    start!(agent_run)
    gate = node(agent_run, "gate")
    assert_equal "dispatched", gate.status

    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_equal "canceling", agent_run.reload.status
    assert_equal "dispatched", gate.reload.status, "the rendezvous is worth waiting for"

    resolved = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: "the external answer"
    )
    assert_predicate resolved, :applied?, "a canceling loop still settles its parks"
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", agent_run.reload.status
    assert_equal "completed", gate.reload.status
  end

  test "a graceful stop escalates: stopping again with force ends the wait" do
    agent_run = seed(model("slow"))
    start!(agent_run)
    invocation = ModelInvocation.find(node(agent_run, "slow").selected_model_invocation_id)

    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_equal "queued", invocation.reload.status, "graceful leaves it running"

    AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_equal "canceled", invocation.reload.status, "force ends the wait NOW"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", agent_run.reload.status
  end

  test "canceling a pending loop settles it at once, and cancel converges idempotently" do
    agent_run = seed(model("unstarted"))

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "unstarted").status

    again = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_equal :already_terminal, again.outcome
  end

  test "a timed-out step holds like any halt failure and abandon resolves it" do
    agent_run = seed(model("slowpoke"))
    start!(agent_run)
    slowpoke = node(agent_run, "slowpoke")
    step_attempt(agent_run)
    # The deadline sweep's own write, applied by the converger like any
    # terminal.
    ModelInvocation.lock.find(slowpoke.selected_model_invocation_id)
      .terminalize(status: "timed_out", reason_key: "deadline_passed")
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)

    slowpoke.reload
    assert_equal "timed_out", slowpoke.status
    assert_equal "deadline_passed", slowpoke.error_key
    assert_equal "needs_attention", agent_run.reload.status

    abandoned = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
      agent_run: agent_run, task_key: "slowpoke", acting_user: @human
    ))
    assert_predicate abandoned, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "deliverable_unresolved", agent_run.attention_reason,
      "the deliverable was abandoned, not answered — the kernel never synthesizes"
  end

  test "the schedule sweep drains a canceling loop whose wake was lost" do
    agent_run = seed(model("inflight"))
    start!(agent_run)
    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_equal "canceling", agent_run.reload.status, "the wake never ran"

    AgentRuns::ScheduleSweepJob.perform_now
    assert_equal "canceled", agent_run.reload.status
  end

  test "a designated deliverable decides quiescence, and a background result is delivered, never a hold" do
    agent_run = seed(model("answer"), detached(tool("side")))
    start!(agent_run)
    run_step!(agent_run, sse_success("the answer"), key: "answer")
    assert_equal "running", agent_run.reload.status, "the answer is in, the background tool still out"

    AgentRuns::Parks::Settle.call(node: node(agent_run, "side"), trusted: true,
      content: "denied", is_error: true, outcome: "completed")
    schedule!(agent_run)
    wake = node(agent_run, "w1")
    assert_equal %w[answer side], wake.input_from_node_keys, "the wake reads the tip beside the mainline"
    run_step!(agent_run, sse_success("noted"), key: "w1")

    assert_equal "completed", agent_run.reload.status,
      "the wake's round is the answer now; the side's error result held nothing"
  end

  test "stopping a held loop settles its waiting tasks with it" do
    agent_run = seed(model("brittle"), model("starved"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "queued", node(agent_run, "starved").status

    # The clock no longer ends a hold — stop is the terminal exit, and it must not leave
    # live-looking work behind.
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "starved").status,
      "a terminal loop never carries live-looking waiting tasks"
  end

  test "an authority cut stops the loop the way a cancel does" do
    agent_run = seed(model("head"), model("tail"))
    start!(agent_run)

    # The cut: archive cancels the in-flight step once; the loop row is
    # still running and its sweeps would otherwise keep minting.
    @workspace.reload.accept_archive
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)

    agent_run.reload
    assert_equal "canceled", agent_run.status,
      "the scheduler's authority recheck kills the loop instead of minting under cut authority"
    assert_equal "authority_lost", agent_run.failure_reason
    # The formula settled the dependent first: its source was canceled, so
    # it SKIPPED — either way, nothing waits inside the dead loop.
    assert_equal "skipped", node(agent_run, "tail").status
    assert_equal 1, ModelInvocation.where(agent_run_id: agent_run.id).count,
      "no invocation was ever minted after the cut"
  end

  test "a verified billing subject rides every step's usage receipt" do
    agent_run = seed(model("billed"), billing_subject: "client-x")
    assert_equal "client-x", agent_run.billing_subject_key
    assert_not_nil agent_run.billing_subject_public_id

    start!(agent_run)
    invocation = ModelInvocation.find(node(agent_run, "billed").selected_model_invocation_id)
    run_step!(agent_run, sse_success("paid work"))

    receipt = UsageRecord.find_by!(model_invocation_public_id: invocation.public_id)
    assert_equal "client-x", receipt.billing_subject_key
    assert_equal agent_run.billing_subject_public_id, receipt.billing_subject_public_id
  end

  test "a billing subject owned by someone else refuses the create" do
    owner_result = BillingSubjects::CreateOrVerify.call(
      account: @account, acting_user: users(:owner), key: "owners-key"
    )
    assert_predicate owner_result, :verified?

    result = create_loop(model("t"), billing_subject: "owners-key")
    assert_equal :billing_subject_not_owned, result.outcome
  end

  test "cancel is the default: a settled race stops its losers, unless the author says run_out" do
    agent_run = seed(parallel(model("quick"), model("slow"), until: "any", key: "race"), model("after"))
    start!(agent_run)
    run_step!(agent_run, sse_success("quick wins"), key: "quick")

    assert_equal "completed", node(agent_run, "race").status
    assert_equal "canceled", ModelInvocation.find(node(agent_run, "slow").selected_model_invocation_id).status,
      "the one spend control under no ceilings: a race's losers stop"

    honest = seed(parallel(model("quick"), model("slow"), until: "any", key: "race", losers: "run_out"),
      model("after"))
    start!(honest)
    run_step!(honest, sse_success("quick wins"), key: "quick")
    assert_equal "completed", node(honest, "race").status
    assert_equal "running", node(honest, "slow").status,
      "honest spend when asked for: the loser finishes and its answer stays available"
  end

  # Abandonment is per consumer: a pending ancestor is a loser only when
  # every consumer of it is terminal or itself a loser, which spares work
  # another live branch still needs (the closure's own fixpoint).
  test "cancel_losers stops the losing branch and everything only it was feeding" do
    agent_run = seed(
      parallel(model("quick"), [model("slow-head"), model("slow-tail")], until: "any", key: "race"),
      model("after", "prompt" => "carry on")
    )
    start!(agent_run)
    # `quick` and `slow-head` both run; slow-tail waits behind slow-head.
    run_step!(agent_run, sse_success("quick wins"), key: "quick")

    assert_equal "completed", node(agent_run, "race").status
    assert_equal "canceled", node(agent_run, "slow-tail").status,
      "the join's own pending source stops at once"
    # slow-head was RUNNING: its invocation terminalizes, the node settles
    # when the converger applies that terminal (the two-phase shape).
    head = node(agent_run, "slow-head")
    assert_equal "canceled",
      ModelInvocation.find(head.selected_model_invocation_id).status,
      "the upstream that only the losing branch needed stops spending too"
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", head.reload.status
    assert_equal "running", node(agent_run, "after").status,
      "the winner's dependents are untouched"
  end

  test "a quorum that goes unreachable stops the sources still in flight" do
    agent_run = seed(
      parallel([model("a", "on_failure" => "propagate"), model("b")], model("c"), until: 2, key: "q"),
      model("after")
    )
    start!(agent_run)
    # `a` fails and propagates, so `b` skips: successes 0 + pending 1 < 2.
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "a")

    q = node(agent_run, "q")
    assert_equal "failed", q.status
    assert_equal "quorum_unreachable", q.error_key
    c = node(agent_run, "c")
    assert_equal "canceled", ModelInvocation.find(c.selected_model_invocation_id).status,
      "a FAILED race ends the race: `c` can no longer feed anything"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    c.reload
    assert_equal "canceled", c.status
    assert_equal "join_loser_canceled", c.error_key,
      "the cancel's own reason survives onto the task"
  end

  test "a promptless model step is refused on the door, and a kernel one fails honestly at schedule" do
    assert_equal [{ "code" => "prompt_required", "path" => "steps[0].prompt" }],
      create_loop(model("empty", "prompt" => nil)).errors

    fresh = AgentRun.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")
    fresh.create_conversation_event_cursor!(account: fresh.account)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: fresh, origin: "kernel", steps: [AgentRuns::Tasks::Step::Model.new(key: "empty", model: MOCK_MODEL)],
      tip: AgentRuns::Tasks::Tip.seed("round")
    ))
    assert_predicate appended, :applied?
    start!(fresh)

    empty = node(fresh, "empty")
    assert_equal "failed", empty.status
    assert_equal "missing_input", empty.error_key
  end
end
