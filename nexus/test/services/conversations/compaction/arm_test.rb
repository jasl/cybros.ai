require "test_helper"

# THE DELEGATE'S ADDRESSEE AND ITS FALLBACK. A delegated compaction is a tool call addressed to the
# loop's DECLARING profile's address — on a standalone agent loop, on a loop-backed turn a person
# typed on the agent's conversation, and on the between-turn summary loop alike; never
# `creating_user`'s, which on a person's turn has no address at all. When NOBODY answers it — the
# row expires at its park — the kernel's own summarizer runs once in its place from the one
# quiescence site, narrated with what it fell from; a second failure is the honest size failure, and
# a delegate that ANSWERED is never repaired. Both hosts run through the real chain; only the HTTP
# adapter is faked.
class Conversations::Compaction::ArmTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  BULK = ("the quick brown fox files a report. " * 600).freeze
  TOOL = "my_compactor".freeze
  DELEGATE = { "mode" => "delegate", "tool_name" => TOOL }.freeze
  # A profile the sweep may not replay blind: its expiry is `uncertain`.
  WRITE_PROFILE = {
    "kind" => "write", "destructive" => true, "effect_scope" => "open",
    "idempotency" => "none", "reconciliation" => "none",
  }.freeze
  Fallback = Conversations::Compaction::Fallback

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  def address = Executor.address_for(@agent)

  # Text at prose's own token rate on the real tiktoken counter.
  def prose(bytes) = ("the quick brown fox files a report. " * (bytes / 36.0).ceil).byteslice(0, bytes)

  # The agent's address announcing the delegate under `profile`, credential-ready.
  def announce!(profile = Nexus::ToolRegistry::READ_ONLY_CLOSED)
    unless Executor.credential_readiness_for([address]).fetch(address.id) == :ready
      create_bound_credential(executor: address, name: "Lane transport")
    end
    announced = address.announce(services: { address.executor_kind => { "tools" => [{ "name" => TOOL, "effect_profile" => profile }] } })
    assert_predicate announced, :accepted?, announced.detail.to_s
  end

  def schedule!(run) = Runs::ScheduleReady.call(run_id: run.id)

  def node(run, key) = run.tasks.find_by!(node_key: key)

  # The agent's own two rounds stopped one pass short of the wall: round
  # one settled, and the caller's `schedule!` is the pass that arms.
  def run_at_the_wall(compaction: DELEGATE, lifetime: "conversation")
    round1 = model("round1", "instructions" => "be useful", "prompt" => BULK)
    round2 = model("round2", "prompt" => BULK, "compaction" => compaction, "lifetime" => lifetime)
    run = seed(round1, round2, creating_user: @agent)
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @agent))
    schedule!(run)
    schedule!(run)
    settle!(run, "round1", "here is what I found")
    run
  end

  def step_attempt(run, key)
    invocation_id = node(run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call.admitted
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def settle!(run, key, text)
    apply_via(step_attempt(run, key), sse_success(text))
    Runs::ConvergeTerminalSteps.call
  end

  # A deterministic request failure ends the invocation; absorb releases
  # its dependent work without repeating the same provider request.
  def fail_step!(run, key)
    apply_via(step_attempt(run, key), json_response(400, { "error" => "bad" }))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
  end

  def claim!(run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: key, executor: address
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit!(run, key, token, content:, outcome: "completed", is_error: false)
    result = Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: key, executor: address, claim_token: token, content: content,
      structured_content: nil, result_type: nil, outcome: outcome, is_error: is_error, title: nil, metadata: nil
    ))
    assert_predicate result, :applied?, result.outcome.inspect
  end

  # The deadline first, then the sweep — the unit suites' expiry.
  def expire!(run, key)
    Task.where(id: node(run, key).id).update_all(await_started_at: 2.hours.ago)
    clear_enqueued_jobs
    Runs::Parks::TimeoutSweep.call
  end

  def compacted_items(host)
    host.event_items.where(item_type: "context_compacted").order(:sequence).map(&:payload)
  end

  def request_texts(node)
    round_request_entries(node).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  # A conversation the AGENT created, declaring the delegate; a person's
  # words on it drained into message turns.
  def agent_conversation!(turns: 3)
    declare_tools!(@agent, compaction_policy: DELEGATE)
    announce!
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    turns.times { |n| post_input!(conversation, acting_user: @human, text: "turn#{n} #{SecureRandom.hex(1_200)}") }
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    conversation
  end

  # The between-turn host: the manual door as the agent, whose declared
  # policy is the delegate — the summary turn and its one-task loop.
  def delegated_summary_turn!(conversation)
    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    turn = conversation.turns.find_by!(kind: "compaction_summary")
    run = turn.active_variant.run
    clear_enqueued_jobs
    schedule!(run)
    [turn, run]
  end

  # ══════════════════════════════════════════════════════════════════════
  # THE ADDRESSEE: the declaring profile's address, on both hosts
  # ══════════════════════════════════════════════════════════════════════

  test "on a standalone agent loop the delegate is addressed to the agent's own announcing address" do
    announce!
    run = run_at_the_wall
    schedule!(run)

    k1 = node(run, "k1")
    assert_equal "tool_task", k1.task_kind
    assert_equal "dispatched", k1.status
    assert_equal address.id, k1.addressed_executor_id, "the declaring profile's own address"
    # The binding is the runner-kind ROW the seed named — an announced agent address is never a
    # binding — so the one addressing site reaches the delegate as the agent's own tool.
    assert_equal suite_runner.id, run.default_runner_executor_id,
      "the named runner-kind row — an announced agent address is never a binding"
    assert_equal "agent", k1.addressed_role
    assert_equal Nexus::ToolRegistry::READ_ONLY_CLOSED, k1.effect_profile, "the announced profile, frozen"
    assert_equal "k1", node(run, "round2").compaction["summary_source"]
    assert_equal({ "run_public_id" => run.public_id, "task" => "round2" },
      k1.tool_input.slice("run_public_id", "task", "conversation", "turn"))
  end

  # A person typed on the agent's conversation: the loop's `creating_user`
  # is the person (no address at all), its declaring profile the agent.
  test "on a loop-backed turn a person authored, the delegate reaches the AGENT's address, never the author's" do
    declare_tools!(@agent, compaction_policy: DELEGATE)
    announce!
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    post_input!(conversation, acting_user: @human, text: "read the index")
    post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "what is up",
      provider_id: "dev", model_ref: "mock-text")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    turn = conversation.turns.order(:position).last
    run = turn.active_variant.run
    assert_equal @human, run.creating_user
    assert_nil Executor.address_for(@human), "a person has no address"
    assert_equal @agent, conversation.answering_user, "the creator answers its own conversation by default"
    assert_equal @agent, run.execution_agent

    schedule_loop!(run)
    run_loop_round!(run, sse_success(prose(40_000), tool_calls: [
      { id: "call_a", name: "read_file", arguments: %({"path":"docs/index.txt"}) },
    ]))
    Runs::Parks::Settle.call(
      node: run.tasks.find_by!(tool_call_id: "call_a"), trusted: true,
      content: "a small file\n", outcome: "completed"
    )
    schedule_loop!(run)

    k1 = loop_node(run, "k1")
    assert_equal "tool_task", k1.task_kind
    assert_equal TOOL, k1.tool_name
    assert_equal "dispatched", k1.status
    assert_equal address.id, k1.addressed_executor_id
    assert_equal "agent", k1.addressed_role, "nothing bound: the agent's own tool"
    assert_equal({ "conversation" => conversation.public_id, "turn" => turn.public_id, "task" => "r2" },
      k1.tool_input.slice("conversation", "turn", "task", "run_public_id"))

    # AND ITS FALLBACK NAMES THE TURN, as the delegate's own item did: the
    # conversation's feed carries the loop and the turn it backs on both.
    claim!(run, "k1")
    expire!(run, "k1")
    delegate_item, fallback_item = compacted_items(conversation).last(2)
    assert_equal({ "mode" => "delegate", "turn_public_id" => turn.public_id, "task_key" => "r2", "summary_task_key" => "k1" },
      delegate_item.slice("mode", "turn_public_id", "task_key", "summary_task_key"))
    assert_equal({ "mode" => "kernel", "trigger" => "fallback", "turn_public_id" => turn.public_id, "task_key" => "r2",
                   "summary_task_key" => "k2", "fallback_from" => "k1", "fallback_reason" => "tool_timeout",
                   "run_public_id" => run.public_id,
                   "variant_public_id" => run.variant.public_id }, fallback_item)
  end

  test "between turns the summary loop's seed is the delegate, addressed to the agent" do
    conversation = agent_conversation!
    turn, run = delegated_summary_turn!(conversation)

    k1 = node(run, "k1")
    assert_equal "tool_task", k1.task_kind
    assert_equal TOOL, k1.tool_name
    assert_equal "dispatched", k1.status
    assert_equal address.id, k1.addressed_executor_id
    assert_equal run.deliverable_node_id, k1.id, "the whole seed is the deliverable"
    assert_equal({ "conversation" => conversation.public_id, "turn" => turn.public_id },
      k1.tool_input.slice("conversation", "turn", "task", "run_public_id"))
    assert_equal "delegate", compacted_items(conversation).sole["mode"]
  end

  test "a kernel summary is read by a later authored follower that names it" do
    conversation = agent_conversation!(turns: 1)
    declare_tools!(@agent, compaction_policy: { "mode" => "kernel" })
    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    run = result.value.turn.active_variant.run

    grow!(run, model("follow-summary", "prompt" => "Use the summary.", "results" => ["k1"]))
    follower = node(run, "follow-summary")
    assert_equal ["k1"], follower.result_from_node_keys
    assert_nil follower.input_from_node_keys
    assert_equal ["k1"], follower.sources.map(&:node_key)

    schedule_loop!(run)
    run_loop_round!(run, sse_success("THE KERNEL SUMMARY"))
    assert_equal "running", follower.reload.status
    assert request_texts(follower).any? { |text| text.include?("THE KERNEL SUMMARY") }
  end

  # For a delegate nobody serves: a refusal at start is a failure the model reads, not an expiry —
  # nothing falls back.
  test "a delegate the agent does not announce fails tool_not_served and the round fails on size" do
    run = run_at_the_wall
    schedule!(run)
    k1 = node(run, "k1")
    assert_equal %w[failed tool_not_served absorb], k1.values_at(:status, :error_key, :on_failure)

    2.times { schedule!(run) }
    round2 = node(run, "round2")
    assert_equal "failed", round2.status
    assert_includes Runs::ScheduleReady::SIZE_REFUSALS.map(&:to_s), round2.error_key
    assert_nil run.tasks.find_by(node_key: "k2"), "not an expiry: no fallback"
    assert_nil round2.arrived_summary
    assert_not Conversations::Compaction::Arm.fallback(run.reload)
  end

  # ══════════════════════════════════════════════════════════════════════
  # A DELEGATE THAT ANSWERED IS THE AGENT'S ANSWER, WHATEVER IT SAID
  # ══════════════════════════════════════════════════════════════════════

  test "a delegate that ran and errored is not a summary, and is not repaired" do
    announce!
    run = run_at_the_wall
    schedule!(run)
    token = claim!(run, "k1")
    commit!(run, "k1", token, content: "boom: the summarizer crashed", is_error: true)

    k1 = node(run, "k1")
    assert_equal "completed", k1.status
    assert_equal true, k1.output_summary["is_error"]
    assert_nil node(run, "round2").arrived_summary, "an error text is never read as history"
    assert_not Conversations::Compaction::Arm.fallback(run.reload)
    assert_nil run.tasks.find_by(node_key: "k2")
  end

  test "a delegate that answered failed gets no fallback: the agent's failure is the agent's log" do
    announce!
    run = run_at_the_wall
    schedule!(run)
    token = claim!(run, "k1")
    commit!(run, "k1", token, content: "no model available", outcome: "failed")

    k1 = node(run, "k1")
    assert_equal %w[failed tool_failed absorb], k1.values_at(:status, :error_key, :on_failure)
    assert_nil run.tasks.find_by(node_key: "k2")
    assert_nil node(run, "round2").arrived_summary
    assert_equal ["delegate"], compacted_items(run).map { |item| item["mode"] }
  end

  # ══════════════════════════════════════════════════════════════════════
  # THE FALLBACK: a delegate NOBODY answered
  # ══════════════════════════════════════════════════════════════════════

  # The fallback is the kernel's step on the agent's own loop, so it reads the agent's `summarizer`
  # slot as the arm's own step does: the profile's text, never the delegate's.
  SLOT_TEXT = "Summarize by pointers; end on the next action.".freeze

  test "mid-turn, an expired delegate is replaced once by the kernel summarizer the round then reads" do
    announce!
    assert_predicate PromptDocuments::Write.call(anchor: { user: @agent }, slot: "summarizer", content: SLOT_TEXT),
      :written?
    run = run_at_the_wall(lifetime: "turn")
    schedule!(run)
    claim!(run, "k1")
    expire!(run, "k1")

    k1 = node(run, "k1")
    assert_equal "turn", k1.lifetime, "the repair inherits the repaired round's lifetime"
    assert_equal %w[timed_out tool_timeout absorb], k1.values_at(:status, :error_key, :on_failure),
      "announced replayable, the expiry is a plain timeout"
    assert_equal({ Fallback::DELEGATE_FALLBACK => "k2" }, k1.compaction, "the fence, on the expired row")

    k2 = node(run, "k2")
    assert_equal "turn", k2.lifetime, "fallback retains the same execution's completion obligation"
    assert_equal "model_task", k2.task_kind
    assert_equal "queued", k2.status
    assert_nil k2.compaction, "the kernel's own step is never armed"
    assert_equal SLOT_TEXT, k2.system_instructions, "the fallback reads the agent's summarizer slot"
    round2 = node(run, "round2")
    assert_equal "queued", round2.status
    assert_equal 1, round2.remaining_dependencies, "the round waits on the new root"
    assert_equal "k2", round2.compaction["summary_source"], "re-marked to read the fallback"
    assert_equal "delegate", round2.compaction["mode"]

    items = compacted_items(run)
    assert_equal [
      { "run_public_id" => run.public_id, "task_key" => "round2", "summary_task_key" => "k1",
        "mode" => "delegate", "trigger" => "wall" },
      { "run_public_id" => run.public_id, "task_key" => "round2", "summary_task_key" => "k2",
        "mode" => "kernel", "trigger" => "fallback", "fallback_from" => "k1", "fallback_reason" => "tool_timeout" },
    ], items

    schedule!(run)
    assert_equal "running", node(run, "k2").status
    settle!(run, "k2", "THE FALLBACK SUMMARY")
    schedule!(run)
    round2 = node(run, "round2")
    assert_equal "running", round2.status
    texts = request_texts(round2)
    assert texts.any? { |text| text.include?("Mock: THE FALLBACK SUMMARY") }, texts.inspect
    assert_not texts.any? { |text| text.include?("here is what I found") }, "the summary replaces the history"
  end

  test "an uncertain expiry falls back too, and says so" do
    announce!(WRITE_PROFILE)
    run = run_at_the_wall
    schedule!(run)
    claim!(run, "k1")
    expire!(run, "k1")

    k1 = node(run, "k1")
    assert_equal %w[uncertain tool_uncertain absorb], k1.values_at(:status, :error_key, :on_failure)
    assert_equal({ Fallback::DELEGATE_FALLBACK => "k2" }, k1.compaction)
    assert_equal "queued", node(run, "k2").status
    fallback = compacted_items(run).last
    assert_equal %w[fallback k1 tool_uncertain k2],
      fallback.values_at("trigger", "fallback_from", "fallback_reason", "summary_task_key")
  end

  test "between turns, the expired delegate's loop gains the kernel summarizer as its deliverable and the turn adopts it" do
    conversation = agent_conversation!
    turn, run = delegated_summary_turn!(conversation)
    claim!(run, "k1")
    expire!(run, "k1")

    k1 = node(run, "k1")
    assert_equal %w[timed_out tool_timeout absorb], k1.values_at(:status, :error_key, :on_failure)
    assert_equal({ Fallback::DELEGATE_FALLBACK => "k2" }, k1.compaction)
    k2 = node(run, "k2")
    assert_equal "model_task", k2.task_kind
    assert_equal "queued", k2.status
    assert_equal 0, k2.remaining_dependencies, "born ready behind an absorbed settlement"
    assert_equal k2.id, run.reload.deliverable_node_id
    assert_equal "running", run.status, "not held: the loop still owes its summary"

    items = compacted_items(conversation)
    assert_equal %w[delegate kernel], items.map { |item| item["mode"] }
    assert_equal({
      "turn_public_id" => turn.public_id, "run_public_id" => run.public_id,
      "variant_public_id" => run.variant.public_id,
      "summary_task_key" => "k2", "summary_turn_public_id" => turn.public_id,
      "mode" => "kernel", "trigger" => "fallback", "fallback_from" => "k1", "fallback_reason" => "tool_timeout",
    }, items.last)

    schedule_loop!(run)
    run_loop_round!(run, sse_success("THE FALLBACK SUMMARY"))
    assert_equal "completed", run.reload.status
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_includes turn.active_variant.content_bodies.find_by!(role: "content").effective_text,
      "THE FALLBACK SUMMARY"
  end

  test "a cost refused delegate fallback keeps the summary input pending and retries only its model" do
    conversation = agent_conversation!
    turn, run = delegated_summary_turn!(conversation)
    head = post_input!(conversation, acting_user: @human, text: "continue after the summary")
    claim!(run, "k1")
    expire!(run, "k1")
    schedule!(run)
    fallback = node(run, "k2")
    invocation = ModelInvocation.find(fallback.selected_model_invocation_id)
    invocation.with_lock { invocation.terminalize(status: "failed", reason_key: Conversation::COST_LIMIT_REACHED) }
    Runs::ConvergeTerminalSteps.call
    schedule!(run)
    Conversations::Turns::Converge.call

    assert_equal ["needs_attention", "halt_failure"], run.reload.values_at(:status, :attention_reason)
    assert_equal "halt_failure", run.turn_shape.failure_reason_key
    assert_equal Conversation::COST_LIMIT_REACHED, Runs::Transition.newest_blocking_error_key(run)
    assert_equal "failed", turn.reload.status
    assert_equal 0, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    assert_equal "pending", head.reload.state
    assert_equal %w[k1 k2], run.tasks.order(:node_key).pluck(:node_key)
    assert_not Conversations::Compaction::Arm.fallback(run)

    repaired = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "k2", acting_user: @human
    ))
    assert_predicate repaired, :accepted?
    schedule!(run)
    settle!(run, "k2", "THE FALLBACK SUMMARY")
    schedule!(run)
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    assert_equal ["timed_out", 0], node(run, "k1").values_at(:status, :execution_generation)
    assert_equal ["completed", 1], node(run, "k2").values_at(:status, :execution_generation)
    assert_equal %w[delegate kernel], compacted_items(conversation).map { |item| item["mode"] }
  end

  test "an authored follower after fallback reads the replacement summary it names" do
    conversation = agent_conversation!(turns: 1)
    _turn, run = delegated_summary_turn!(conversation)
    claim!(run, "k1")
    expire!(run, "k1")
    assert_equal "k2", run.reload.deliverable_node.node_key

    grow!(run, model("follow-summary", "prompt" => "Use the replacement summary.", "results" => ["k2"]))
    follower = node(run, "follow-summary")
    assert_equal ["k2"], follower.result_from_node_keys
    assert_nil follower.input_from_node_keys
    assert_equal ["k2"], follower.sources.map(&:node_key)

    schedule_loop!(run)
    run_loop_round!(run, sse_success("THE FALLBACK SUMMARY"))
    assert_equal "running", follower.reload.status
    assert request_texts(follower).any? { |text| text.include?("THE FALLBACK SUMMARY") }
  end

  test "once: when the kernel summarizer fails too, nothing falls back again and the round fails on size" do
    announce!
    run = run_at_the_wall
    schedule!(run)
    claim!(run, "k1")
    expire!(run, "k1")
    schedule!(run)
    assert_equal "running", node(run, "k2").status

    fail_step!(run, "k2")
    k2 = node(run, "k2")
    assert_equal %w[failed absorb], k2.values_at(:status, :on_failure)
    2.times { schedule!(run) }
    round2 = node(run, "round2")
    assert_equal "failed", round2.status
    assert_includes Runs::ScheduleReady::SIZE_REFUSALS.map(&:to_s), round2.error_key
    assert_nil run.tasks.find_by(node_key: "k3"), "a second failure is the honest size failure"
    assert_equal %w[delegate kernel], compacted_items(run).map { |item| item["mode"] }
    assert_not Conversations::Compaction::Arm.fallback(run.reload)
  end

  test "between turns, a failed fallback holds the turn as a failed repair does" do
    conversation = agent_conversation!
    turn, run = delegated_summary_turn!(conversation)
    claim!(run, "k1")
    expire!(run, "k1")
    schedule_loop!(run)

    fail_step!(run, "k2")
    Conversations::Turns::Converge.call
    assert_equal "needs_attention", run.reload.status
    assert_equal "deliverable_unresolved", run.attention_reason
    assert_equal "failed", turn.reload.status
    assert_nil run.tasks.find_by(node_key: "k3")
  end

  # The fallback answers false on every loop without an expired delegate,
  # and a kernel-mode wall never meets it.
  test "the fallback is silent for a loop with nothing to fall back from" do
    run = run_at_the_wall(compaction: { "mode" => "kernel" })
    schedule!(run)
    assert_equal "model_task", node(run, "k1").task_kind
    assert_not Conversations::Compaction::Arm.fallback(run.reload)
    assert_nil run.tasks.find_by(node_key: "k2")
  end
end
