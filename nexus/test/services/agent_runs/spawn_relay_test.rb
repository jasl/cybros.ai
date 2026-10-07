require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# THE CHILD-REPLY RELAY: a spawned child's settled reply reaches its parent ONCE — as the paired
# result of a waited spawn's kernel-held await, settled trusted, or as kernel mail on the parent
# (`origin: child`, authored as `ResultDelivery` is: the parent loop's creator, the child's identity riding
# the sender stamp and the envelope's `conversation=`). LEVEL-TRIGGERED: the converger's kick at
# both turn terminals is a latency hint; the durable marker is `conversation_turns.relayed_at`,
# written by a guarded stamp after either path succeeds (or once the turn is judged nothing owed),
# and a recurring sweep walks the spawned children's unrelayed replies. Only turns the PARENT opened
# are owed (the seed's sender stamp is the parent's) — a person's own word into the child is theirs.
# Driven through the REAL chain: the parent's round spawns, the child's engine replies, the turn
# converger settles, the relay job runs.
class AgentRuns::SpawnRelayTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include AgentMembershipTestHelper
  include RowLockTestHelper
  include ActiveSupport::Testing::ConstantStubbing

  uses_transaction :test_a_kick_and_the_recurring_relay_deliver_one_waited_reply

  PROMPT = "Review app/models/user.rb for N+1 queries; keep the findings, I will ask follow-ups.".freeze
  REPLY = "Three N+1s: user.rb:12, :40, :77.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
  end

  def say!(text) = post_input!(@conversation, acting_user: @human, text: text)

  def open_turn!(text = "go")
    say!(text)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  def attempt_for(agent_run, key)
    attempt_of(loop_node(agent_run, key).selected_model_invocation_id)
  end

  def attempt_of(invocation_id)
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  def spawn_round!(agent_run, *calls, key: "r1")
    tool_calls = calls.each_with_index.map do |fields, index|
      { id: "call_#{index}", name: "spawn", arguments: fields.to_json }
    end
    apply_via(attempt_for(agent_run, key), sse_success("delegating", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::ConversationToolJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.reload
  end

  def run_round!(agent_run, key, text)
    apply_via(attempt_for(agent_run, key), sse_success(text))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end

  # The parent spawns and finishes its own turn: idle, so mail may wake it.
  def spawning_parent!(*calls)
    turn, agent_run = open_turn!
    spawn_round!(agent_run, *calls)
    [turn, agent_run]
  end

  def finish_parent!(agent_run, key = "r2")
    run_round!(agent_run, key, "meanwhile, here is what I know")
    converge!
  end

  def call_node(agent_run, key = "r2t0") = loop_node(agent_run, key)
  def child_of(agent_run, key = "r2t0") = Conversation.find_by!(spawn_node_id: call_node(agent_run, key).id)

  # The child's engine answers its brief: the loop-backed reply runs one
  # round and completes; the turn converger settles the turn.
  def child_replies!(child, text = REPLY)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.conversation_turns.order(:position).last
    child_loop = turn.active_variant.agent_run
    schedule_loop!(child_loop)
    run_round!(child_loop, "r1", text)
    turn
  end

  def converge! = Conversations::Turns::Converge.call

  def relay!(*args) = AgentRuns::Spawn::RelayJob.perform_now(*args)

  def reply_turn(child) = child.conversation_turns.where(kind: "direct_reply", role: "assistant").order(:position).last

  def paired_results(agent_run, key)
    round_request_entries(loop_node(agent_run, key)).select { |payload| payload["type"] == "tool_result_item" }
      .to_h { |payload| [payload.dig("payload", "call_id"), payload.dig("payload", "output")] }
  end

  def request_texts(node)
    round_request_entries(node).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  def spawn_envelope(call, status, child, text)
    "<task_result task=\"#{call}\" status=\"#{status}\" conversation=\"#{child.public_id}\">\n#{text}\n</task_result>"
  end

  def declined_reply(invocation)
    "(the reply ended failed: #{invocation.provider_id}/#{invocation.model_ref} declined it, so it has no text)\n" \
      "#{AgentRuns::TaskResultEnvelope::DECLINED}"
  end

  def receipt_keys = ConversationCommandReceipt.where(operation: "input_create").pluck(:idempotency_key)

  def task_status_items(key)
    @conversation.conversation_event_items.where(item_type: "task_status").order(:sequence)
      .map(&:payload).select { |payload| payload["task_key"] == key }
  end

  # ── the mail path ────────────────────────────────────────────────────

  test "a detached child's reply is kernel mail on the parent: origin child, authored as ResultDelivery is, stamped once" do
    turn, agent_run = spawning_parent!({ prompt: PROMPT })
    finish_parent!(agent_run)
    assert_equal "completed", turn.reload.status
    child = child_of(agent_run)
    child_turn = child_replies!(child)

    assert_enqueued_with(job: AgentRuns::Spawn::RelayJob, args: [child.id]) do
      converge!
    end
    assert_equal "completed", child_turn.reload.status
    assert_nil child_turn.relayed_at, "the kick is a hint; the marker is the relay's"
    assert_equal 0, @conversation.conversation_inputs.count

    relay!(child.id)
    mail = @conversation.conversation_inputs.sole
    assert_equal %w[direct_reply user queue pending child],
      [mail.kind, mail.role, mail.delivery_mode, mail.state, mail.origin],
      "a queued reply, never a steer; the kernel's own word `child`"
    assert_equal child.public_id, mail.sender_conversation_public_id, "the child's identity rides the stamp"
    assert_equal agent_run.creating_user_id, mail.authoring_user_id,
      "authored as ResultDelivery is: the parent loop's creator, never the child's answerer"
    assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), mail.text
    variant = agent_run.conversation_turn_variant
    assert_equal [variant.provider_id, variant.model_ref], [mail.provider_id, mail.model_ref],
      "the woken turn rides the SPAWNING loop's surface"
    assert_equal %w[delegate_task read_file spawn], mail.tool_names
    accepted = @conversation.conversation_event_items.where(item_type: "input_accepted").order(:sequence).last.payload
    assert_equal ["child", agent_run.public_id, "r2t0"], accepted.values_at("origin", "run_public_id", "task_key")
    assert_equal 0, @conversation.conversation_inputs.caller_authored.count, "not counted against the caller's bound"
    assert_not_nil child_turn.reload.relayed_at, "the durable marker"
    assert_includes receipt_keys, "spawn:#{child.public_id}:#{child_turn.public_id}", "the receipt is the inner guard"

    relay!(child.id)
    relay!
    assert_equal 1, @conversation.conversation_inputs.count, "delivered once under a retried job and under the sweep"

    # Idle, the receipt WAKES the parent: the woken turn's trailing user
    # message is the child's reply in the spawn envelope, drained FIRST.
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    woken_turn = @conversation.conversation_turns.order(:position).last
    assert_equal %w[direct_reply assistant running child], [woken_turn.kind, woken_turn.role, woken_turn.status, woken_turn.origin]
    assert_equal child.public_id, woken_turn.sender_conversation_public_id
    woken = woken_turn.active_variant.agent_run
    schedule_loop!(woken)
    assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), request_texts(loop_node(woken, "r1")).last
  end

  # THE RELAY'S ADDRESSEE: the child's reply is mailed to the SPAWNING TURN's answerer — the agent
  # whose `spawn` it was — never to the conversation's default and never to everyone.
  test "a child's reply on a Human-default conversation is mailed to the spawning turn's answerer" do
    plain = Conversation.create!(workspace: @workspace, creating_user: @human)
    @conversation = plain
    post_input!(plain, acting_user: @human, kind: "direct_reply", text: "delegate the review",
      provider_id: "dev", model_ref: "mock-text", answering_user_public_id: "@#{@agent.handle}")
    Conversations::Inputs::ApplyNext.drain(conversation_id: plain.id)
    turn = plain.conversation_turns.order(:position).last
    agent_run = turn.active_variant.agent_run
    assert_equal [@agent, @human], [agent_run.answering_user, plain.answering_user]
    schedule_loop!(agent_run)
    spawn_round!(agent_run, { prompt: PROMPT })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    child_replies!(child)
    converge!

    relay!(child.id)
    mail = plain.conversation_inputs.sole
    assert_equal [@agent, "child", @human], [mail.answering_user, mail.origin, mail.authoring_user],
      "addressed to the spawning loop's answerer, authored by its creator"
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: plain.id)
    woken = plain.conversation_turns.order(:position).last
    assert_equal [@agent, "child"], [woken.answering_user, woken.origin], "the reply wakes the agent's turn, not the Human's"
  end

  test "a lost kick is caught by the sweep: the unrelayed reply is found and mailed" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    child_replies!(child)
    converge!
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: AgentRuns::Spawn::RelayJob) { relay! }
    assert_equal 1, @conversation.conversation_inputs.count, "the sweep found it"
    assert_not_nil reply_turn(child).relayed_at
    assert_equal 0, AgentRuns::Spawn::Relay.call[:relayed], "and then there is nothing to do"
  end

  test "a tool-less peer's plain reply reaches the relay through the converger's other terminal" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    assert_empty Array(peer.tool_definitions), "no tools: the child's reply is one model call, never a loop"
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, agent: "@#{peer.handle}" })
    finish_parent!(agent_run)
    child = child_of(agent_run)

    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = reply_turn(child)
    assert_equal "inference", child_turn.active_variant.source
    apply_via(attempt_of(child_turn.active_variant.model_invocation_id), sse_success("looks fine"))
    assert_enqueued_with(job: AgentRuns::Spawn::RelayJob, args: [child.id]) { converge! }
    assert_equal "completed", child_turn.reload.status

    relay!(child.id)
    mail = @conversation.conversation_inputs.sole
    assert_equal spawn_envelope("r2t0", "completed", child, "Mock: looks fine"), mail.text
    assert_equal "child", mail.origin
    assert_not_nil child_turn.reload.relayed_at
  end

  # A declined reply failed its work: the parent reads who declined it and
  # what it can do next, never "(the reply ended failed with no text)" —
  # after which the natural move is to send the same brief again.
  test "a tool-less peer's refused reply is mailed as the refusal" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, agent: "@#{peer.handle}" })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = reply_turn(child)
    invocation = child_turn.active_variant.model_invocation
    apply_via(attempt_of(invocation.id), sse_refused("I can't help with that."))
    converge!
    assert_equal "failed", child_turn.reload.status

    relay!(child.id)
    assert_equal spawn_envelope("r2t0", "failed", child, declined_reply(invocation)),
      @conversation.conversation_inputs.sole.text
  end

  # The peer's declared fallback asked again and declined too: the parent
  # reads the refusal that stood — the fallback's — not the first one.
  test "a tool-less peer's reply its fallback declined too is mailed as the fallback's refusal" do
    peer = declare_tools!(create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1"),
      tools: [], fallback_model: "dev/mock-unmetered")
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, agent: "@#{peer.handle}" })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = reply_turn(child)
    apply_via(attempt_of(child_turn.active_variant.model_invocation_id), sse_refused("I can't help with that."))
    converge!
    fallback = child_turn.reload.conversation_turn_variants.find_by!(source: "fallback").model_invocation
    apply_via(attempt_of(fallback.id), sse_refused("Nor can I."))
    converge!
    assert_equal "failed", child_turn.reload.status

    relay!(child.id)
    assert_equal spawn_envelope("r2t0", "failed", child, declined_reply(fallback.reload)),
      @conversation.conversation_inputs.sole.text
  end

  # The paired result and the `wait` tool read the same reply the same way,
  # and neither reads one before the reply's converger has decided it.
  test "a waited tool-less peer's refused reply reads failed on the await and on the wait tool alike" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, agent: "@#{peer.handle}", wait: true })
    child = child_of(agent_run)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    invocation = reply_turn(child).active_variant.model_invocation
    apply_via(attempt_of(invocation.id), sse_refused("I can't help with that."))
    assert_nil AgentRuns::TaskWaits::Observe.call(call_node(agent_run).reload),
      "the reply's converger has not decided yet"

    converge!
    relay!(child.id)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)

    expected = spawn_envelope("r2t0", "failed", child, declined_reply(invocation))
    assert_equal expected, paired_results(agent_run, "r2").fetch("call_0")
    observed = AgentRuns::TaskWaits::Observe.call(call_node(agent_run).reload)
    assert_equal [expected, true, "failed"], [observed.text, observed.error, observed.data["status"]]
  end

  test "only turns the parent opened are owed: a person's own reply in the child is stamped, never relayed" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    child_replies!(child)
    converge!
    relay!(child.id)
    assert_equal 1, @conversation.conversation_inputs.count

    post_input!(child, acting_user: @human, kind: "direct_reply", text: "and the fix?",
      provider_id: "dev", model_ref: "mock-text")
    persons = child_replies!(child, "wrap it in includes")
    assert_equal "person", persons.origin
    assert_nil persons.sender_conversation_public_id
    converge!
    relay!(child.id)

    assert_equal 1, @conversation.conversation_inputs.count, "the person's exchange is theirs"
    assert_not_nil persons.reload.relayed_at, "stamped as nothing owed, so the frontier shrinks"
  end

  test "a tombstoned parent owes nothing: the reply is stamped, not retried forever" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    child_turn = child_replies!(child)
    converge!
    assert_predicate Conversations::Tombstone.call(conversation: @conversation.reload), :accepted?

    relay!(child.id)
    assert_equal 0, @conversation.conversation_inputs.count
    assert_not_nil child_turn.reload.relayed_at
  end

  test "a spawn link reaped after the frontier scan cannot turn a bare parent link into a reply source" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT })
    finish_parent!(agent_run)
    child = child_of(agent_run)
    child_turn = child_replies!(child)
    converge!
    relay = AgentRuns::Spawn::Relay.new(conversation_id: child.id)
    # The sweep already selected this child when detail collection nullified the call link.
    Conversation.where(id: child.id).update_all(spawn_node_id: nil)

    relay.stub(:frontier, [child.id]) { relay.call }

    assert_empty @conversation.reload.conversation_inputs
    assert_not_nil child_turn.reload.relayed_at, "the remaining parent link owes nothing"
  end

  # ── the await path ───────────────────────────────────────────────────

  test "a waited spawn's reply settles the await trusted, names its resolver, and is the paired result — once" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    assert_equal "dispatched", await.status
    child_turn = child_replies!(child)
    converge!

    relay!(child.id)
    assert_equal "completed", await.reload.status, "settled trusted by the kernel's own relay"
    assert_equal REPLY.then { |text| "Mock: #{text}" }, await.content_bodies.find_by(role: "output").effective_text
    assert_not_nil child_turn.reload.relayed_at
    assert_equal 0, @conversation.conversation_inputs.count, "the await path posts no mail"
    resolved = task_status_items("r2t0-spawn-1").last
    assert_equal({ "kind" => "conversation", "public_id" => child.public_id }, resolved.fetch("resolved_by"),
      "the settle's own narration item names the resolver — no column")
    assert_equal "completed", resolved.fetch("status")

    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), paired_results(agent_run, "r2").fetch("call_0")

    relay!(child.id)
    relay!
    assert_equal 0, @conversation.conversation_inputs.count, "the await path settled, then the job retried: nothing twice"
    assert_equal "completed", await.reload.status
  end

  test "a canceled child reply fails the await with the words, and the continuation still runs (absorb)" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = reply_turn(child)
    child_loop = child_turn.active_variant.agent_run
    assert_predicate Conversations::Turns::Cancel.stop_now(child), :accepted?
    AgentRuns::EvaluateQuiescence.call(child_loop.reload)
    converge!
    assert_equal "canceled", child_turn.reload.status

    relay!(child.id)
    await = loop_node(agent_run, "r2t0-spawn-1")
    assert_equal "failed", await.status
    assert_not_nil child_turn.reload.relayed_at
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal spawn_envelope("r2t0", "failed", child, AgentRuns::ResultDelivery.no_reply_text(child_turn)),
      paired_results(agent_run, "r2").fetch("call_0")
    assert_equal "canceled", child_turn.status, "the words name what the child's turn became"
  end

  test "an await the scheduler has not yet parked defers the relay; a later pass settles it" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    AgentRunTask.where(id: await.id).update_all(status: "queued")
    child_turn = child_replies!(child)
    converge!

    relay!(child.id)
    assert_nil child_turn.reload.relayed_at, "neither path: the await exists and is not yet a park"
    assert_equal 0, @conversation.conversation_inputs.count
    assert_equal "queued", await.reload.status

    AgentRunTask.where(id: await.id).update_all(status: "dispatched")
    relay!(child.id)
    assert_equal "completed", await.reload.status
    assert_not_nil child_turn.reload.relayed_at
  end

  test "an expired await sends the reply down the mail path; the await stays timed_out" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    travel_to(await.await_started_at + AgentRunTasks::AwaitTask::DEFAULT_TIMEOUT_MS.fdiv(1000) + 1) do
      assert_predicate AgentRuns::Parks::Settle.call(node: await, timeout: true), :applied?
    end
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    finish_parent!(agent_run)
    child_turn = child_replies!(child)
    converge!

    relay!(child.id)
    assert_equal "timed_out", await.reload.status
    mail = @conversation.conversation_inputs.sole
    assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), mail.text
    assert_not_nil child_turn.reload.relayed_at
  end

  test "a late child reply that expires its await is mailed once instead of discarded" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    child_turn = child_replies!(child)
    converge!
    clear_enqueued_jobs

    travel_to(await.deadline_at + 1.second) do
      assert_equal "dispatched", await.reload.status, "no timeout sweep has visited the park"
      relay!(child.id)

      assert_equal "timed_out", await.reload.status, "the late settle itself expires the park"
      assert_equal 1, @conversation.conversation_inputs.count, "the reply must survive the expiry as mail"
      mail = @conversation.conversation_inputs.sole
      assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), mail.text
      assert_equal "child", mail.origin
      assert_not_nil child_turn.reload.relayed_at
      assert_nil await.content_bodies.find_by(role: "output"), "the expired await did not receive the reply"

      relay!(child.id)
      relay!
      assert_equal [mail.id], @conversation.conversation_inputs.pluck(:id), "the reply is mailed only once"

      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      finish_parent!(agent_run)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      woken_turn = @conversation.conversation_turns.order(:position).last
      assert_equal "child", woken_turn.origin
      woken = woken_turn.active_variant.agent_run
      schedule_loop!(woken)
      assert_equal spawn_envelope("r2t0", "completed", child, "Mock: #{REPLY}"), request_texts(loop_node(woken, "r1")).last
    end
  end

  test "a failed child reply arriving after the await deadline is also mailed once" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "late-reviewer")
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true, agent: "@#{peer.handle}" })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_turn = reply_turn(child)
    apply_via(attempt_of(child_turn.active_variant.model_invocation_id), json_response(400, { "error" => "bad" }))
    converge!
    clear_enqueued_jobs
    assert_equal "failed", child_turn.reload.status

    travel_to(await.deadline_at + 1.second) do
      assert_equal "dispatched", await.reload.status
      relay!(child.id)

      assert_equal "timed_out", await.reload.status
      assert_equal 1, @conversation.conversation_inputs.count, "a failed reply is owed after expiry too"
      mail = @conversation.conversation_inputs.sole
      assert_equal spawn_envelope("r2t0", "failed", child, AgentRuns::ResultDelivery.no_reply_text(child_turn)), mail.text
      assert_not_nil child_turn.reload.relayed_at

      relay!(child.id)
      relay!
      assert_equal [mail.id], @conversation.conversation_inputs.pluck(:id)
    end
  end

  test "a paused parent's frozen deadline still receives the child reply through its await" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    child_turn = child_replies!(child)
    converge!
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs

    travel_to(await.deadline_at + 1.second) do
      relay!(child.id)

      assert_equal "completed", await.reload.status, "wall time cannot expire a paused park"
      assert_equal "Mock: #{REPLY}", await.content_bodies.find_by!(role: "output").effective_text
      assert_equal "paused", agent_run.reload.status
      assert_not_nil child_turn.reload.relayed_at
      assert_equal 0, @conversation.conversation_inputs.count

      relay!(child.id)
      relay!
      assert_equal 0, @conversation.conversation_inputs.count, "the await's reply must not also arrive as mail"
    end
  end

  test "a kick and the recurring relay deliver one waited reply" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    child_turn = child_replies!(child)
    converge!
    clear_enqueued_jobs

    # Both real jobs have read the unrelayed turn before either may settle
    # its await. The ordinary kick and recovery pass meet at the loop owner.
    held = hold_row_lock(AgentRun, agent_run.id)
    calls = [
      start_database_call { relay!(child.id) },
      start_database_call { relay! },
    ]
    wait_until_transitively_blocked_by(held.pid, *calls.map(&:pid))
    release_row_lock(held)
    held = nil
    calls.each { |call| finish_database_call(call) }
    calls = []

    assert_equal "completed", await.reload.status
    assert_equal "Mock: #{REPLY}", await.content_bodies.find_by!(role: "output").effective_text
    assert_not_nil child_turn.reload.relayed_at
    assert_equal 0, @conversation.conversation_inputs.count, "the second relay must not mail an already awaited reply"
    assert_equal 1, task_status_items(await.node_key).count { |item| item["resolved_by"] },
      "the await is resolved once"

    relay!(child.id)
    relay!
    assert_equal 0, @conversation.conversation_inputs.count
  ensure
    release_row_lock(held) if held
    calls&.each { |call| stop_database_call(call) }
    [child, @conversation].compact.each do |conversation|
      # Production reclamation retains receipts; this committed test must
      # also remove its own audit rows before losing their invocation ids.
      ConversationCommandReceipt.where(host: conversation).delete_all
      conversation.hosted_agent_runs.each do |agent_run|
        UsageRecord.where(model_invocation_public_id: agent_run.model_invocations.select(:public_id)).delete_all
        AgentRuns::Reap.destroy_aggregate(agent_run)
      end
      ModelUsageSummary.where(subject_kind: "conversation", subject_id: conversation.id).delete_all
      conversation.reload.destroy!
    end
  end

  test "the await path's settle and the stamp are one transaction: a torn stamp rolls the settle back" do
    _turn, agent_run = spawning_parent!({ prompt: PROMPT, wait: true })
    child = child_of(agent_run)
    await = loop_node(agent_run, "r2t0-spawn-1")
    child_turn = child_replies!(child)
    converge!

    AgentRuns::Spawn::Relay.stub(:stamp, ->(_turn) { raise "torn" }) do
      assert_equal 0, AgentRuns::Spawn::Relay.call(conversation_id: child.id)[:relayed]
    end
    assert_equal "dispatched", await.reload.status, "no settle without its marker"
    assert_nil child_turn.reload.relayed_at

    relay!(child.id)
    assert_equal "completed", await.reload.status
  end

  # ── the sweep's shape ────────────────────────────────────────────────

  test "the sweep is bounded and hop-chained: a full window enqueues one continuation carrying its cursor" do
    _turn, agent_run = spawning_parent!({ prompt: "first" }, { prompt: "second" })
    finish_parent!(agent_run)
    first, second = child_of(agent_run, "r2t0"), child_of(agent_run, "r2t1")
    child_replies!(first)
    child_replies!(second)
    converge!
    clear_enqueued_jobs

    stub_const(AgentRuns::Spawn::Relay, :BUDGET, 1) do
      first_cursor = { "after_id" => first.id, "delegation_after_id" => 0,
                       "children_done" => false, "delegations_done" => true,
                       "variant_after_id" => 0, "variants_done" => true, "inputs_done" => false }
      assert_enqueued_jobs(1, only: AgentRuns::Spawn::RelayJob) { relay! }
      first_cursor["input_after_id"] = @conversation.conversation_inputs.order(:id).last.id
      assert_enqueued_with(job: AgentRuns::Spawn::RelayJob, args: [nil, first_cursor])
      assert_equal 1, @conversation.conversation_inputs.count
      assert_enqueued_jobs(1, only: AgentRuns::Spawn::RelayJob) { relay!(nil, first_cursor) }
      second_cursor = first_cursor.merge("after_id" => second.id,
        "input_after_id" => @conversation.conversation_inputs.order(:id).last.id)
      assert_enqueued_with(job: AgentRuns::Spawn::RelayJob, args: [nil, second_cursor])
      assert_equal 2, @conversation.conversation_inputs.count
      assert_no_enqueued_jobs(only: AgentRuns::Spawn::RelayJob) { relay!(nil, second_cursor) }
    end
    assert_no_enqueued_jobs(only: AgentRuns::Spawn::RelayJob) { relay! }
    assert_equal "AgentRuns::Spawn::RelayJob", recurring_schedule.dig("relay_spawned_replies", "class")
  end
end
