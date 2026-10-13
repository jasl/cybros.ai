require "test_helper"
require_relative "../../test_helpers/agent_runs_execution_test_helper"

# model execution and failure containment, through the REAL chain: start → schedule → step
# invocation → real admission → the real start/build/dispatch path against the fake adapter →
# terminal apply → the step converger → the release walk → quiescence. Only the HTTP adapter is
# faked (the harness's charter).
class AgentRuns::ExecutionTest < ActiveJob::TestCase
  include AgentRunsExecutionTestHelper

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

  test "a transient failure retries within the same invocation and generation" do
    agent_run = seed(model("flaky"))
    start!(agent_run)
    flaky = node(agent_run, "flaky")
    first_invocation_id = flaky.selected_model_invocation_id

    apply_via(step_attempt(agent_run), json_response(503, { "error" => "overloaded" }))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    flaky.reload
    assert_equal "running", flaky.status, "the node still owns its invocation"
    assert_equal 0, flaky.execution_generation
    invocation = ModelInvocation.find(first_invocation_id)
    assert_equal "queued", invocation.status
    invocation.update!(next_admission_at: nil)

    schedule!(agent_run)
    flaky.reload
    assert_equal "running", flaky.status
    assert_equal first_invocation_id, flaky.selected_model_invocation_id
    assert_equal "agent_run_task:#{flaky.id}:0",
      ModelInvocation.find(flaky.selected_model_invocation_id).internal_creation_key

    run_step!(agent_run, sse_success("second try"))
    assert_equal 2, invocation.attempts.count
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
    agent_run = seed(model("solo"))
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
    retried = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "solo", acting_user: @human
    ))
    assert_predicate retried, :accepted?
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
