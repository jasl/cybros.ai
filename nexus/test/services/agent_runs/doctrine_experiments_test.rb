require "test_helper"

# Behavioral experiments for loop invariants. Each case constructs a workflow that would fail if
# steering, continuation or quiescence violated the stated outcome.
class AgentRuns::DoctrineExperimentsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def run_step!(agent_run, key, behaviour)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    target = node(agent_run, key)
    apply_via(@admitted.fetch(target.selected_model_invocation_id), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
  end

  # A steer posted mid-round lands exactly once at the model continuation after the tool fan. The
  # caller addresses the loop and never has to choose one concurrent task.
  test "E2: a steer typed mid-round lands on the continuation, once, naming nothing" do
    agent_run = seed(model("ask", "prompt" => "read them", "tools" => [
      { "type" => "function", "function" => { "name" => "read_file" } },
    ]))
    start!(agent_run)

    # The user steers while a wide fan is still running, without naming any member of that fan.
    run_step!(agent_run, "ask", sse_success("calling", tool_calls: (0..2).map do |n|
      { id: "c#{n}", name: "read_file", arguments: "{\"path\":\"#{n}\"}" }
    end))
    assert_predicate loop_input!(agent_run, acting_user: @human, text: "summarize instead"), :accepted?
    assert_equal 1, agent_run.steering_inputs.count,
      "mid-fan there is no boundary yet: the directive waits rather than " \
        "steering a tool"

    fan = %w[r1t0 r1t1 r1t2]
    fan.each_with_index do |key, index|
      AgentRuns::Parks::Settle.call(node: node(agent_run, key), trusted: true,
        content: "contents #{index}", outcome: "completed")
    end
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    texts = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.filter_map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_equal ["summarize instead"], texts.last(1),
      "it lands at the MERGE POINT — the continuation, after the whole fan, " \
        "as the request's final word"
    assert_equal 0, agent_run.conversation_inputs.count,
      "consumed exactly once; nothing is left to strand"
    assert_equal %w[sender_task_key], ConversationInput.column_names.grep(/task/),
      "the sole task stamp identifies the sender; a steer has no destination task selector"
    refute_includes ConversationInput::DOOR_FIELDS, :sender_task_key,
      "the source stamp is kernel-owned, never caller-selected"
  end

  # E1 — falsifiable claim: the graph grammar covers deterministic
  # workflow authoring, and replay never forks history.
  test "E1: a pi-style pipeline — a quorum of probes, losers canceled, a reduce that reads the winners" do
    key = SecureRandom.uuid
    pipeline = [
      parallel(model("probe-a", "prompt" => "probe a"), model("probe-b", "prompt" => "probe b"),
        model("probe-c", "prompt" => "probe c"), until: 2, key: "quorum"),
      model("reduce", "prompt" => "combine", "results" => ["quorum"]),
    ]
    created = create_loop(*pipeline, idempotency_key: key)
    assert_predicate created, :created?
    agent_run = created.agent_run
    assert_equal "reduce", agent_run.deliverable_node.node_key

    replay = create_loop(*pipeline, idempotency_key: key)
    assert_predicate replay, :replayed?
    assert_equal agent_run.id, replay.agent_run.id, "replay never forks history"
    forked = create_loop(model("probe-a"), idempotency_key: key)
    assert_equal :idempotency_envelope_mismatch, forked.outcome,
      "a DIFFERENT program under the same key is a conflict, never a silent fork"

    start!(agent_run)
    run_step!(agent_run, "probe-a", sse_success("finding a"))
    run_step!(agent_run, "probe-b", sse_success("finding b"))

    quorum = node(agent_run, "quorum")
    assert_equal "completed", quorum.status, "two successes satisfy k=2"
    slow = node(agent_run, "probe-c")
    assert_equal "canceled",
      ModelInvocation.find(slow.selected_model_invocation_id).status,
      "the race ended; the loser stops spending — a public race cancels by default"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    texts = ModelInvocation.find(node(agent_run, "reduce").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.filter_map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_equal ["<task_result task=\"probe-a\" status=\"completed\">\n<prompt>probe a</prompt>\nMock: finding a\n</task_result>",
                  "<task_result task=\"probe-b\" status=\"completed\">\n<prompt>probe b</prompt>\nMock: finding b\n</task_result>",
                  "combine"],
      texts.last(3), "the reduce reads the race it names: the winners, first finisher first, each by its brief, " \
        "never the loser"
    run_step!(agent_run, "reduce", sse_success("combined"))
    assert_equal "completed", agent_run.reload.status
  end

  # E4 — falsifiable claim: the forced pause stops the WHOLE graph, a pause is never a failure, and
  # nothing mints until resume. (The steer half of the gesture on a wide graph is exercised on the
  # compiled graph: two ready tasks are an ambiguous boundary by design.)
  test "E4: the Esc gesture under a wide round, and an authored fan of model steps is one mainline" do
    agent_run = seed(
      parallel(model("left", "prompt" => "left branch"), model("right", "prompt" => "right branch")),
      model("merge", "prompt" => "merge")
    )
    assert_equal %w[branch branch round], %w[left right merge].map { |k| node(agent_run, k).continuation_source },
      "the fan's members are branches; only the follower is the mainline"
    assert_equal "merge", agent_run.mainline_tail.node_key, "and the mainline's tail is never a member"
    start!(agent_run)
    assert_equal 2, ModelInvocation.where(agent_run_id: agent_run.id).count

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    %w[first second].each do |text|
      loop_input!(agent_run, acting_user: @human, text: text)
    end
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    AgentRuns::ScheduleSweepJob.perform_now

    assert_equal 2, ModelInvocation.where(agent_run_id: agent_run.id).count,
      "NOTHING mints between pause(force) and resume — not even the sweep"
    assert_equal %w[queued queued],
      %w[left right].map { |k| node(agent_run, k).status },
      "a pause is not a failure: both steps re-queued for the resume"

    AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    assert_equal 4, ModelInvocation.where(agent_run_id: agent_run.id).count,
      "resume re-mints BOTH branches"
    assert_equal 2, agent_run.steering_inputs.count,
      "two ready tasks are an ambiguous boundary — the steers wait for " \
      "the main-thread rule (S5); E2 takes over this half of the gesture"
  end

  # E5 — the barrier chain authored by hand beside a running mainline — is gone with the edge door:
  # "beside" is a detached step — the door's `detached` or a `task` call without `wait: true` —
  # and the merge is the wake; no verb names a barrier over existing tasks.

  # E6 — falsifiable claim: approval-as-task-state needs no subsystem,
  # and an interrupt during the park spares the rendezvous.
  test "E6: an await gates a destructive step; interrupt spares the park" do
    created = create_loop(
      model("plan", "prompt" => "propose the change"),
      ask("approval", "timeout_ms" => 6.hours.in_milliseconds, "on_failure" => "propagate"),
      model("apply", "prompt" => "apply it")
    )
    agent_run = created.agent_run
    receipt_tokens = created.receipt.fetch("resolution_tokens")
    start!(agent_run)
    run_step!(agent_run, "plan", sse_success("the proposal"))

    approval = node(agent_run, "approval")
    assert_equal "dispatched", approval.status, "parked, awaiting the human"
    assert_equal "queued", node(agent_run, "apply").status,
      "the destructive step cannot start before the approval"

    # A forced pause while the approval parks: nothing to abort, the park
    # survives — stopping the agent's reasoning is not denying approval.
    paused = AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    ))
    assert_predicate paused, :accepted?
    assert_equal "dispatched", approval.reload.status
    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?

    resolved = AgentRuns::Parks::Settle.call(
      node: approval, claim_token: receipt_tokens.fetch("approval"),
      content: "approved: ship it"
    )
    assert_predicate resolved, :applied?
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "running", node(agent_run, "apply").status

    run_step!(agent_run, "apply", sse_success("applied"))
    assert_equal "completed", agent_run.reload.status
  end

  # E8 — falsifiable claim: the one-dimensional reading is first-class —
  # a checklist authored as a chain runs strictly in order and every
  # projection stays legible.
  test "E8: a twelve-step checklist as a chain, each step replaying the one before" do
    keys = (1..12).map { |n| "step-#{format("%02d", n)}" }
    agent_run = seed(*keys.map { |key| model(key, "prompt" => "do #{key}") })
    assert_equal [keys[10]], node(agent_run, keys.last).input_from_node_keys,
      "written order is the whole wiring: each step reads the step before it"
    start!(agent_run)

    keys.each do |key|
      assert_equal "running", node(agent_run, key).status,
        "#{key} runs exactly when its turn comes"
      assert_equal 1,
        agent_run.agent_run_tasks.where(status: "running").count,
        "a chain is one-at-a-time by construction"
      run_step!(agent_run, key, sse_success("#{key} done"))
    end

    assert_equal "completed", agent_run.reload.status
    assert_equal 11, agent_run.agent_run_edges.count, "the shape is a chain"
    statuses = AgentAPI::AgentRunPresenter.full(agent_run)[:tasks].map { |t| t[:status] }
    assert_equal ["completed"] * 12, statuses, "the list projection reads as a checklist"
  end
end
