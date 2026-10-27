require "test_helper"

# `send`, `status`, `cancel`: ONE executor keyed by verb, dispatched by the one conversation-tool
# job, addressing through the one resolver (`Conversations::ConversationAddress`). `send` is the
# SENDER's own row on the addressee through the one input door (`Command.sent`: author = the sender,
# kind on the row as `origin: agent`, the sender conversation's stamp) — queued by default, a STEER
# when the agent chose it and a reply is running there; standing is the sender's `full` on the
# addressee as the door judges it; a child's `send` into the parent blocking on it is
# `parent_waiting` (B10). `status` is the three facts the model can act on, and a fourth when
# messages from the addressee wait for the caller. `cancel` stops the addressee's executions and
# their derived requests; a reply the sender was owed still arrives, marked canceled. Driven through the REAL
# chain: the round's call, the approval stage, the job, the door.
class Runs::ConversationToolTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include AgentMembershipTestHelper

  PROMPT = "Review app/models/user.rb for N+1 queries and keep the findings; I will ask follow-ups.".freeze
  MORE = "Also check app/models/account.rb:90.".freeze
  Run = Runs::ConversationTool::Run

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, Nexus::Tools::SEND, Nexus::Tools::REQUEST,
                                   Nexus::Tools::STATUS, Nexus::Tools::CANCEL, READ_TOOL], default_model: "dev/mock-text")
  end

  def say!(text) = post_input!(@conversation, acting_user: @human, text: text)

  def open_turn!(text = "go")
    say!(text)
    turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(run)
    [turn, run]
  end

  def attempt_for(run, key)
    invocation_id = loop_node(run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with kernel calls; the kernel's jobs run.
  def call_round!(run, key, *calls)
    tool_calls = calls.each_with_index.map do |(name, fields), index|
      { id: "call_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(attempt_for(run, key), sse_success("working", tool_calls: tool_calls))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    run.reload
  end

  # A parent turn whose round r1 spawned one child (the call is r2t0), the
  # continuation r2 running: the next calls are r3t*.
  def spawning_loop(**fields)
    _turn, run = open_turn!
    call_round!(run, "r1", ["spawn", { prompt: PROMPT, **fields }])
  end

  def child_of(run, key = "r2t0") = Conversation.find_by!(spawn_node_id: loop_node(run, key).id)
  def tool_result(run, key) = loop_node(run, key).content_bodies.find_by(role: "output")&.effective_text
  def tool_error?(run, key) = loop_node(run, key).output_summary["is_error"] == true

  # The child's engine takes up its brief: a loop-backed reply, running.
  def running_child!(child)
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.turns.order(:position).last
    child_loop = turn.active_variant.run
    schedule_loop!(child_loop)
    [turn, child_loop]
  end

  def rows_on(conversation) = Input.where(host: conversation).order(:queue_position)

  def accepted_payloads(conversation)
    conversation.event_items.where(item_type: "input_accepted").order(:sequence).map(&:payload)
  end

  def assert_receipt(run, key, input)
    receipt = Runs::TaskResultProjection.call(loop_node(run, key)).fetch("structured_content")
    assert_equal input.public_id, receipt.fetch("input_public_id")
    assert_equal input.host.public_id, receipt.fetch("conversation_public_id")
    assert_equal input.answering_user.public_id, receipt.fetch("answering_user_public_id")
    assert_equal input.state, receipt.fetch("state")
    if input.deliver_at
      assert_equal input.deliver_at.utc.iso8601, receipt["deliver_at"]
    else
      assert_nil receipt["deliver_at"]
    end
    assert_equal receipt, JSON.parse(tool_result(run, key))
  end

  test "a root cancellation stops spawned descendants after their Agent restricts access" do
    parent_loop = spawning_loop
    child = child_of(parent_loop)
    _child_turn, child_loop = running_child!(child)
    call_round!(child_loop, "r1", ["spawn", { prompt: PROMPT }])
    grandchild = child_of(child_loop)
    _grandchild_turn, grandchild_loop = running_child!(grandchild)

    [child, grandchild].each do |conversation|
      assert Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
        conversation: conversation, acting_user: @agent, default: "none", entries: []
      )).accepted?
      assert_not conversation.reload.writable_by?(@human)
    end
    assert @conversation.writable_by?(@human)

    assert_equal :not_authorized, Conversations::Turns::Cancel.call(
      Conversations::Turns::Cancel::Command.new(conversation: child, acting_user: @human)
    ).outcome, "direct child commands still require that child's standing"
    loops = [parent_loop, child_loop, grandchild_loop]
    assert_equal %w[running running running], loops.map { |run| run.reload.status }

    assert Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    )).accepted?
    assert_predicate parent_loop.reload, :stopped?
    [child_loop, grandchild_loop].each do |run|
      assert Runs::SourceWork.execution_stopped?(run.reload),
        "the source cut revokes derived execution before asynchronous cancellation drains it"
    end

    settle_stopped_loops(*loops)
    assert_equal %w[canceled canceled canceled], loops.map { |run| run.reload.status }
    assert_equal %w[canceled canceled canceled],
      loops.map { |run| run.variant.turn.reload.status }
    assert_not child.reload.writable_by?(@human), "stopping spend does not grant access to the child"
  end

  # ── send ─────────────────────────────────────────────────────────────

  test "send by label preserves sender attribution without creating a result obligation" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    call_round!(run, "r2", ["send", { to: "reviewer", message: MORE }])

    _brief, row = rows_on(child).to_a
    assert_equal %w[direct_reply user queue pending agent], [row.kind, row.role, row.delivery_mode, row.state, row.origin],
      "the sender's own word: a reply head, origin `agent`, never a kernel receipt"
    assert_equal @agent, row.authoring_user, "the AUTHOR is the sender; the kernel impersonates nobody"
    assert_equal @conversation.public_id, row.sender_conversation_public_id
    assert_equal MORE, row.text
    assert_equal ["dev", "mock-text"], [row.provider_id, row.model_ref],
      "the receiver declares its own engine"
    assert_equal "message", row.communication_kind
    assert_nil loop_node(run, "r3t0").spawn_delegation
    assert_nil row.tool_names
    assert_equal 2, child.inputs.caller_authored.count, "a peer's send is caller-authored: bound-counted"

    payload = accepted_payloads(child).last
    assert_equal [run.public_id, "r3t0", "agent", @conversation.public_id],
      payload.values_at("run_public_id", "task_key", "origin", "sender_conversation_public_id")
    assert_equal({ "kind" => "agent", "handle" => @agent.handle, "display_name" => @agent.display_name },
      payload.fetch("authored_by"), "the payload names the author: kind, handle, display name")

    assert_equal "completed", loop_node(run, "r3t0").status
    refute tool_error?(run, "r3t0")
    assert_receipt(run, "r3t0", rows_on(child).last)
    assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [child.id])
  end

  test "send by public id into a conversation the sender may write in, not its child, promises nothing" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: peer)
    run = spawning_loop
    call_round!(run, "r2", ["send", { to: other.public_id, message: MORE }])

    row = rows_on(other).sole
    assert_equal [@agent, "agent", @conversation.public_id, MORE],
      [row.authoring_user, row.origin, row.sender_conversation_public_id, row.text]
    assert_receipt(run, "r3t0", row)
  end

  test "a parent link without a spawn or scheduled source promises no automatic reply" do
    child = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id)
    _turn, run = open_turn!
    call_round!(run, "r1", ["send", { to: child.public_id, message: MORE }])

    assert_nil child.spawn_node
    assert_not_predicate child, :scheduled_execution?
    assert_equal MORE, rows_on(child).sole.text
    assert_receipt(run, "r2t0", rows_on(child).sole)
  end

  test "a later request to a child still reports after the original spawning turn was stopped" do
    original = spawning_loop(label: "reviewer")
    child = child_of(original)
    _original_child_turn, original_child_loop = running_child!(child)
    assert Conversations::Turns::Cancel.stop_tree(@conversation).accepted?
    settle_stopped_loops(original, original_child_loop)
    Runs::Spawn::Relay.call(conversation_id: child.id)
    assert original.reload.canceled_unanswered?
    assert_empty rows_on(@conversation).where(origin: "child")

    _turn, later = open_turn!("Continue with the existing reviewer")
    call_round!(later, "r1", ["request", { to: "reviewer", prompt: MORE, lifetime: "conversation" }])
    assert_equal "pending", rows_on(child).sole.state, "steer on this idle child starts a fresh request"
    assert loop_node(later, "r2t0").spawn_delegation
    finish_reply(later, "r2", "Waiting for the reviewer")
    child_turn, child_loop = running_child!(child)
    finish_reply(child_loop, "r1", "Review finished")
    assert_equal "completed", child_turn.reload.status

    2.times { Runs::Spawn::Relay.call; Runs::ResultDelivery.call(later.reload) }
    assert_equal 1, rows_on(@conversation).where(origin: "child").count
    mail = rows_on(@conversation).where(origin: "child").sole
    assert_includes mail.text, "Review finished"
    assert_equal later.public_id,
      accepted_payloads(@conversation).last.fetch("run_public_id"),
      "the request that sent this follow-up owns its reply"
    assert_not_nil child_turn.reload.relayed_at
  end

  test "a later agent's queued request receives the child reply on its own execution surface" do
    original = spawning_loop(label: "reviewer", wait: true)
    child = child_of(original)
    _first_turn, first_loop = running_child!(child)
    finish_reply(first_loop, "r1", "First review")
    Runs::Spawn::Relay.call(conversation_id: child.id)
    Runs::ScheduleReady.call(run_id: original.id)
    finish_reply(original, "r2", "First request done")

    peer = create_agent_member(display_name: "Follow-up", agent_identifier: "follow-up")
    declare_tools!(peer, tools: [Nexus::Tools::REQUEST, Nexus::Tools::STATUS, READ_TOOL],
      approval_rules: [{ "tool" => "request|status", "verdict" => "allow" }], default_model: "dev/mock-unmetered")
    command = Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @human, kind: "direct_reply", role: "user",
      entries: [{ "text" => "Ask the existing reviewer one more question" }],
      delivery_mode: "queue", answering_user_public_id: peer.public_id,
      visible_in_context: true, context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil,
      tool_names: %w[request status], approval_mode: "ask"
    )
    assert Conversations::Inputs::Create.call(command).accepted?
    _later_turn, later = running_child!(@conversation)
    call_round!(later, "r1", ["status", { to: "reviewer" }], ["request", { to: "reviewer", prompt: MORE, lifetime: "conversation" }])
    assert_equal "completed", loop_node(later, "r2t1").status
    finish_reply(later, "r2", "Waiting for the reviewer")

    child_turn, child_loop = running_child!(child)
    finish_reply(child_loop, "r1", "Follow-up review")
    2.times { Runs::Spawn::Relay.call; Runs::ResultDelivery.call(later.reload) }

    mail = rows_on(@conversation).where(origin: "child").sole
    assert_equal peer, mail.answering_user, "the follow-up is owed to the agent that sent it"
    assert_equal @human, mail.authoring_user, "kernel mail retains the sending execution's creator"
    assert_equal ["dev", "mock-unmetered", "ask", %w[request status]],
      [mail.provider_id, mail.model_ref, mail.approval_mode, mail.tool_names]
    assert_includes mail.text, '<task_result task="r2t1"'
    assert_equal [later.public_id, "r2t1"],
      accepted_payloads(@conversation).last.values_at("run_public_id", "task_key")
    assert_not_nil child_turn.reload.relayed_at

    reply_turn, reply_loop = running_child!(@conversation)
    assert_equal peer, reply_turn.answering_user
    assert_equal ["mock-unmetered", "ask", %w[request status]],
      [reply_turn.active_variant.model_ref, reply_loop.approval_mode,
       Runs::BranchTools.names(loop_node(reply_loop, "r1"))]
  end

  test "a same-loop send cannot settle the original spawn await after its brief was removed" do
    _turn, run = open_turn!
    call_round!(run, "r1",
      ["spawn", { prompt: PROMPT, label: "reviewer", wait: true }],
      ["send", { to: "reviewer", message: MORE }])
    child = child_of(run)
    brief = rows_on(child).first
    assert Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: child, input_public_id: brief.public_id, acting_user: @agent
    )).accepted?
    child_turn, child_loop = running_child!(child)
    finish_reply(child_loop, "r1", "Only the follow-up was answered")

    2.times { Runs::Spawn::Relay.call(conversation_id: child.id) }
    assert_equal "failed", loop_node(run, "r2t0-spawn-1").status,
      "removing the brief fails its own wait; an ordinary message cannot replace its result"
    completion = loop_node(run, "r2t0").spawn_delegation
    assert_equal "delegation_abandoned", completion.error_key
    refute_includes completion.output_body.effective_text, "Only the follow-up was answered"
    assert_empty rows_on(@conversation).where(origin: "child")
    assert_nil child_turn.reload.relayed_at, "the ordinary message has no result obligation"
  end

  test "stopping a later requesting turn suppresses its child's reply even when the spawning turn completed" do
    original = spawning_loop(label: "reviewer")
    child = child_of(original)
    _original_child_turn, original_child_loop = running_child!(child)
    finish_reply(original_child_loop, "r1", "First review")
    finish_reply(original, "r2", "First request done")
    Runs::Spawn::Relay.call(conversation_id: child.id)
    assert_equal [:delivered], Runs::ResultDelivery.call(original.reload)
    _receipt_turn, receipt_loop = running_child!(@conversation)
    finish_reply(receipt_loop, "r1", "First review received")
    assert original.reload.delivered?

    _turn, later = open_turn!("Review one more file")
    call_round!(later, "r1", ["request", { to: "reviewer", prompt: MORE, lifetime: "conversation" }])
    child_turn, child_loop = running_child!(child)
    assert Conversations::Turns::Cancel.stop_tree(@conversation).accepted?
    settle_stopped_loops(later, child_loop)
    assert later.reload.canceled_unanswered?
    assert_equal "canceled", child_turn.reload.status

    2.times { Runs::Spawn::Relay.call; Runs::ResultDelivery.call(later.reload) }
    assert_not_nil child_turn.reload.relayed_at
    assert_empty rows_on(@conversation).where(origin: "child"),
      "a canceled request cannot restart the parent through the original completed spawn"
  end

  def finish_reply(run, key, text)
    apply_via(attempt_for(run, key), sse_success(text))
    Runs::ConvergeTerminalSteps.call
    Runs::ScheduleReady.call(run_id: run.id)
    Conversations::Turns::Converge.call
  end

  def settle_stopped_loops(*loops)
    # The scheduler first discovers each source cut and cancels its invocation;
    # convergence applies those terminals before a second scheduler pass drains.
    loops.each { |run| Runs::ScheduleReady.call(run_id: run.id) }
    Runs::ConvergeTerminalSteps.call
    loops.each do |run|
      Runs::ScheduleReady.call(run_id: run.id)
    end
    Conversations::Turns::Converge.call
  end

  # THE INITIATOR'S MODEL ON `send`: the call's `model`, else the sending turn's, rides the row and
  # is read only when the addressee has no preset and no history there; a named model this account
  # may not run is refused at the call with the resolver's word.
  test "request carries a named model to a conversation with no engine of its own, and an unauthorized one is refused" do
    fresh = Conversation.create!(workspace: @workspace, creating_user: @human)
    run = spawning_loop
    call_round!(run, "r2", ["request", { to: fresh.public_id, prompt: MORE, model: "dev/mock-unmetered" }],
      ["request", { to: fresh.public_id, prompt: MORE, model: "dev/no-such-model" }])

    row = rows_on(fresh).sole
    assert_equal ["dev", "mock-unmetered", nil], [row.provider_id, row.model_ref, row.reasoning_effort],
      "no engine there: the call's `model`, at the model's own reasoning default"
    assert_equal 'model_not_authorized: model: "dev/no-such-model" is not a model you may run here (unknown_model).',
      tool_result(run, "r3t1")
    assert tool_error?(run, "r3t1")
    refute tool_error?(run, "r3t0")
  end

  # THE ADDRESSEE'S ENGINE: the reply a `send` opens runs on the addressee's own preset, else the
  # target conversation's own model trio — its last reply turn's — else the sender's surface.
  test "send answers on the receiver preset or conversation history without importing sender configuration" do
    fresh = Conversation.create!(workspace: @workspace, creating_user: @human)
    seasoned = Conversation.create!(workspace: @workspace, creating_user: @human)
    post_input!(seasoned, acting_user: @human, kind: "direct_reply", text: "hi", provider_id: "dev", model_ref: "mock-unmetered")
    Conversations::Inputs::ApplyNext.drain(conversation_id: seasoned.id)
    last = seasoned.turns.order(:position).last
    assert_equal %w[dev mock-unmetered], [last.active_variant.provider_id, last.active_variant.model_ref]
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    apply_via(ModelInvocationAttempt.where(model_invocation_id: last.active_variant.model_invocation_id).order(:id).last,
      sse_success("hello"))
    Conversations::Turns::Converge.call
    assert_equal "completed", last.reload.status

    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    preset = create_agent_member(display_name: "Preset", agent_identifier: "preset-1")
    declare_tools!(preset, tools: [READ_TOOL], default_model: "dev/mock-windowless")
    run = spawning_loop
    sender = run.variant
    assert_equal %w[dev mock-text], [sender.provider_id, sender.model_ref]
    call_round!(run, "r2", ["send", { to: seasoned.public_id, message: MORE }],
      ["send", { to: fresh.public_id, message: MORE }],
      ["send", { to: seasoned.public_id, agent: "@#{peer.handle}", message: MORE }],
      ["send", { to: seasoned.public_id, agent: "@#{preset.handle}", message: MORE }])

    plain, addressed, own = rows_on(seasoned).to_a
    assert_equal %w[dev mock-unmetered], [plain.provider_id, plain.model_ref],
      "the addressee's conversation, the addressee's engine: its last reply turn's trio"
    assert_nil rows_on(fresh).sole.provider_id
    assert_nil rows_on(fresh).sole.model_ref, "an unconfigured receiver must not import the sender model"
    assert_equal [peer, "dev", "mock-unmetered"], [addressed.answering_user, addressed.provider_id, addressed.model_ref],
      "an `agent` that never answered there: the conversation's last reply turn's trio, the one order's second step"
    assert_equal [preset, "dev", "mock-windowless", nil],
      [own.answering_user, own.provider_id, own.model_ref, own.reasoning_effort],
      "an `agent` with a default_model: step 0, whatever the conversation ran on or the sender named"
  end

  test "send uses an unavailable addressee preset's fallback but refuses an explicitly hidden model" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    declare_tools!(peer, tools: [READ_TOOL], default_model: "dev/mock-text-only", fallback_models: ["dev/mock-text"])
    room = Conversation.create!(workspace: @workspace, creating_user: @human)
    run = spawning_loop
    policy = @account.model_provider_configs.find_by!(provider_id: "dev")
    policy.set_model_visibility("dev/mock-text-only", visible: false)
    policy.save!

    call_round!(run, "r2", ["send", { to: room.public_id, agent: "@#{peer.handle}", message: MORE }],
      ["request", { to: room.public_id, agent: "@#{peer.handle}", prompt: MORE, model: "dev/mock-text-only" }])
    refute tool_error?(run, "r3t0")
    assert tool_error?(run, "r3t1")
    assert_includes tool_result(run, "r3t1"), "model_not_authorized"
    assert_equal 1, rows_on(room).count
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: room.id)
    turn = room.turns.sole
    assert_equal peer, turn.answering_user
    assert_equal %w[dev mock-text], [turn.active_variant.provider_id, turn.active_variant.model_ref]
  end

  # THE ADDRESSEE INSIDE THE CONVERSATION: `to` is WHERE and `agent` is WHO — a principal by @handle
  # or public id, the door's one member `answering_user_public_id`, so the row and the turn it opens
  # are that agent's (a group's addressed word); absent, the conversation's own answerer, the plain
  # send. A name that is nobody's is refused with the agents it could have named (spawn's sentence);
  # a Human, or a profile without standing there, is the door's `answerer_not_eligible` by name.
  test "send agent: addresses a principal inside the conversation; an unknown or ineligible name is refused" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    room = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    run = spawning_loop
    call_round!(run, "r2", ["send", { to: room.public_id, agent: "@#{peer.handle}", message: MORE }],
      ["send", { to: room.public_id, agent: peer.public_id, message: MORE }],
      ["send", { to: room.public_id, agent: "@#{@agent.handle}", message: MORE }],
      ["send", { to: room.public_id, agent: "@nobody", message: MORE }],
      ["send", { to: room.public_id, agent: "@#{@human.handle}", message: MORE }])

    by_handle, by_id, own = rows_on(room).to_a
    assert_equal [peer, peer, @agent], [by_handle.answering_user, by_id.answering_user, own.answering_user],
      "the row's answerer is the named agent; the conversation's own answerer named is the plain send"
    assert_equal [@agent] * 3, [by_handle, by_id, own].map(&:authoring_user), "the author stays the sender"
    assert_equal [@conversation.public_id] * 3, [by_handle, by_id, own].map(&:sender_conversation_public_id)
    assert_receipt(run, "r3t0", by_handle)
    assert_receipt(run, "r3t1", by_id)
    assert_receipt(run, "r3t2", own)
    unknown = tool_result(run, "r3t3")
    assert_match(/\Aagent: "@nobody" names no member of this account\. The agents are: /, unknown)
    assert_includes unknown, "@#{peer.handle}"
    assert_equal format(Run::NOT_ELIGIBLE, "@#{@human.handle}", room.public_id), tool_result(run, "r3t4")
    assert %w[r3t3 r3t4].all? { |key| tool_error?(run, key) }
    assert_equal 3, rows_on(room).count, "a refusal posts nothing"
    refute_predicate loop_node(run, "r3"), :terminal?, "one bad call never fails the round"
  end

  test "the own-conversation send queues like any row" do
    run = spawning_loop
    call_round!(run, "r2", ["send", { to: @conversation.public_id, message: "note to self: check :90" }])

    row = rows_on(@conversation).where(origin: "agent").sole
    assert_equal %w[pending queue], [row.state, row.delivery_mode]
    assert_equal @agent, row.authoring_user
    assert_equal @conversation.public_id, row.sender_conversation_public_id
    assert_receipt(run, "r3t0", row)
  end

  # THE MODEL HALF OF THE CLOCK: `deliver_in` — the form a clockless model can use — and
  # `deliver_at` — for a model that was told a wall-clock time — through the SAME parser the member
  # door calls; the row on the addressee carries the resolved time, the one kick is scheduled at it,
  # the settle names it, and the authored time intent is in the call's idempotency envelope.
  test "send deliver_in schedules the row at now + N and deliver_at with an offset as given; the settle names the time" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    before = Time.current
    call_round!(run, "r2", ["send", { to: "reviewer", message: MORE, deliver_in: "20m" }],
      ["send", { to: "reviewer", message: MORE, deliver_at: "2027-01-01T09:00:00+08:00" }])

    _brief, delayed, dated = rows_on(child).to_a
    assert_in_delta before + 20.minutes, delayed.deliver_at, 5, "the delay is measured from the kernel's clock"
    assert_equal delayed.deliver_at, delayed.deliver_at.floor, "the resolved time is canonical: whole seconds"
    assert_equal Time.utc(2027, 1, 1, 1), dated.deliver_at, "an absolute time with an offset, held in UTC"
    assert_equal %w[pending pending], [delayed.state, dated.state]
    assert_receipt(run, "r3t0", delayed)
    assert_receipt(run, "r3t1", dated)
    refute tool_error?(run, "r3t0")

    kicks = enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob && job[:args] == [child.id] }
    assert_includes kicks.map { |job| job[:at] }, delayed.deliver_at.to_f, "the receipt's own kick, at the time"
    assert_includes kicks.map { |job| job[:at] }, dated.deliver_at.to_f

    receipt = ConversationCommandReceipt.find_by!(idempotency_key: "send:#{run.public_id}:r3t1")
    envelope = { "send" => child.public_id, "agent" => nil, "text" => MORE, "delivery_mode" => "queue",
                 "expected_steering_run_public_id" => nil, "on_target_end" => nil, "link_public_id" => nil,
                 "deliver_at" => "2027-01-01T01:00:00Z" }
    assert_equal ConversationCommandReceipt.digest_for(operation: :input_create, envelope: envelope),
      receipt.request_digest, "the canonical string is digested: a replay naming another time mismatches"
  end

  test "send's time refusals: a naive stamp, junk and both name the grammar; steer with a time and a past time are the door's words" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    call_round!(run, "r2",
      ["send", { to: "reviewer", message: MORE, deliver_at: "2026-09-16T09:00:00" }],
      ["send", { to: "reviewer", message: MORE, deliver_in: "soon" }],
      ["send", { to: "reviewer", message: MORE, deliver_in: "1h", deliver_at: "2027-01-01T00:00:00Z" }],
      ["send", { to: @conversation.public_id, message: MORE, deliver_in: "1h", delivery_mode: "steer",
                 expected_steering_run_public_id: run.public_id }],
      ["send", { to: "reviewer", message: MORE, deliver_at: "2020-01-01T00:00:00Z" }],
      ["send", { to: "reviewer", message: MORE, deliver_at: "2099-01-01T00:00:00Z" }])

    %w[r3t0 r3t1 r3t2].each do |key|
      assert tool_error?(run, key), key
      assert_equal Run::TIME_REFUSED, tool_result(run, key), key
    end
    assert_equal format(Run::NOT_SCHEDULABLE, @conversation.public_id), tool_result(run, "r3t3")
    assert_equal format(Run::IN_PAST, "2020-01-01T00:00:00Z", child.public_id), tool_result(run, "r3t4")
    assert_equal format(Run::TOO_FAR, "2099-01-01T00:00:00Z", child.public_id), tool_result(run, "r3t5")
    assert %w[r3t3 r3t4 r3t5].all? { |key| tool_error?(run, key) }
    assert_equal 1, rows_on(child).count, "a refusal posts nothing"
  end

  # A SELF-TIMER: `to` = the sender's own conversation resolves ("it is not
  # above itself"), so a model wakes itself at a time with its own words —
  # a row on its own conversation, `origin: agent`, due later; the
  # operator's evidence is the `input_accepted` event's `deliver_at`
  # beside that origin.
  test "the own-conversation send with deliver_in is a row on the sender's conversation, due later, narrated" do
    run = spawning_loop
    before = Time.current
    call_round!(run, "r2", ["send", { to: @conversation.public_id, message: "check the deploy", deliver_in: "20m" }])

    row = rows_on(@conversation).where(origin: "agent").sole
    assert_in_delta before + 20.minutes, row.deliver_at, 5
    assert_equal ["pending", "direct_reply", @agent, @conversation.public_id],
      [row.state, row.kind, row.authoring_user, row.sender_conversation_public_id]
    assert_receipt(run, "r3t0", row)
    payload = accepted_payloads(@conversation).last
    assert_equal [row.deliver_at.utc.iso8601, "agent"], payload.values_at("deliver_at", "origin")
  end

  test "the existing input steer binds to the running reply and never creates another result obligation" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    child_turn, child_loop = running_child!(child)
    row = post_input!(child, acting_user: @agent, text: "stop: wrong file", delivery_mode: "steer")
    assert_equal %w[steering steer], [row.state, row.delivery_mode]
    assert_equal child_turn, row.steering_target_turn
    assert_equal @agent, row.authoring_user
    call_round!(child_loop, "r1", ["status", { to: child.public_id }])
    assert_empty rows_on(child)
    finish_reply(child_loop, "r2", "The original review, with the correction")
    2.times { Runs::Spawn::Relay.call(conversation_id: child.id) }
    assert_empty rows_on(@conversation).where(origin: "child"), "formal mail waits for the requester's final reply"
    finish_reply(run, "r2", "Waiting for the corrected review")
    Runs::ResultDelivery.call(run.reload)
    assert_includes rows_on(@conversation).where(origin: "child").sole.text, '<task_result task="r2t0"'
    assert_not_nil child_turn.reload.relayed_at
    idle = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    row = post_input!(idle, acting_user: @agent, text: "hello", delivery_mode: "steer")
    assert_equal "pending", row.state, "the ordinary member input door retains its idle fallback"
  end

  test "the row is idempotent under a retried job: one send, one row" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    call_round!(run, "r2", ["send", { to: "reviewer", message: MORE }])
    call = loop_node(run, "r3t0")
    assert_equal :not_running, Run.call(node: call.reload)
    assert_equal 2, rows_on(child).count, "the brief and ONE send"
    assert_receipt(run, "r3t0", rows_on(child).last)
  end

  test "a timed send publishes input and task result atomically and replay retains its deadline" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    apply_via(attempt_for(run, "r2"), sse_success("working", tool_calls: [
      { id: "call_0", name: "send", arguments: { to: "reviewer", message: MORE, deliver_in: "1s" }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    Runs::ScheduleReady.call(run_id: run.id)
    call = loop_node(run, "r3t0")
    Runs::KernelTool.stub(:settle, ->(*) { raise IOError, "settlement interrupted" }) do
      assert_raises(IOError) { Runs::ConversationToolJob.perform_now(call.id) }
    end
    assert_equal 1, rows_on(child).count, "failed publication left only the original brief"
    assert_equal "running", call.reload.status
    assert_nil tool_result(run, "r3t0")
    assert_equal :applied, Run.call(node: call)
    input = rows_on(child).last
    deadline = input.deliver_at
    assert_receipt(run, "r3t0", input)
    travel_to deadline + 25.hours do
      Runs::ConversationToolJob.perform_now(call.id)
      assert_receipt(run, "r3t0", input)
    end
    assert_equal deadline, input.reload.deliver_at
    assert_equal 2, rows_on(child).count
  end

  # ── send's refusals ──────────────────────────────────────────────────

  test "a read-level addressee refuses by name: the door's not_authorized; a full queue likewise" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    readable = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: peer,
      access_default: "read")
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    child.update!(input_queue_limit: 1)
    call_round!(run, "r2", ["send", { to: readable.public_id, message: MORE }],
      ["send", { to: "reviewer", message: MORE }])

    assert tool_error?(run, "r3t0")
    assert_equal format(Run::NOT_AUTHORIZED, readable.public_id), tool_result(run, "r3t0")
    assert_equal 0, rows_on(readable).count, "a refusal posts nothing"
    assert tool_error?(run, "r3t1")
    assert_equal format(Run::DOOR_REFUSED, "input_queue_full", child.public_id), tool_result(run, "r3t1")
    assert_equal 1, rows_on(child).count
  end

  test "an unknown label, a concealed id, a side and an empty message are refused by name" do
    concealed = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @human,
      access_default: "none")
    side = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent, side: true)
    run = spawning_loop(label: "reviewer")
    call_round!(run, "r2", ["send", { to: "linter", message: MORE }],
      ["send", { to: concealed.public_id, message: MORE }],
      ["send", { to: side.public_id, message: MORE }],
      ["send", { to: "reviewer", message: "  " }])

    assert_equal format(Run::UNKNOWN, "linter".inspect), tool_result(run, "r3t0")
    assert_equal format(Run::UNKNOWN, concealed.public_id.inspect), tool_result(run, "r3t1")
    assert_equal format(Run::SIDE, side.public_id), tool_result(run, "r3t2")
    assert_equal Run::EMPTY_MESSAGE, tool_result(run, "r3t3")
    assert %w[r3t0 r3t1 r3t2 r3t3].all? { |key| tool_error?(run, key) }
    assert_equal 0, Input.where(origin: "agent").where.not(host: child_of(run)).count
    refute_predicate loop_node(run, "r3"), :terminal?, "one bad call never fails the round"
  end

  test "a child may not send to or cancel its ancestor; while the parent blocks on it, the word is parent_waiting" do
    run = spawning_loop
    child = child_of(run)
    _child_turn, child_loop = running_child!(child)
    call_round!(child_loop, "r1", ["send", { to: @conversation.public_id, message: "done early" }],
      ["cancel", { to: @conversation.public_id }],
      ["status", { to: @conversation.public_id }])

    assert_equal format(Run::ANCESTOR, @conversation.public_id), tool_result(child_loop, "r2t0")
    assert_equal format(Run::ANCESTOR, @conversation.public_id), tool_result(child_loop, "r2t1")
    assert tool_error?(child_loop, "r2t0") && tool_error?(child_loop, "r2t1")
    assert_equal 0, rows_on(@conversation).where(origin: "agent").count
    assert_equal "running", @conversation.reload.turns.active.sole.status
    assert_equal "conversation #{@conversation.public_id} — running; queue: 0 waiting; answered by @#{@agent.handle}.",
      tool_result(child_loop, "r2t2"), "status reads an ancestor freely"

    # A fresh parent turn: the first is still running its continuation.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    waited = spawning_loop(wait: true)
    blocked_child = child_of(waited)
    assert_equal "dispatched", loop_node(waited, "r2t0-spawn-1").status
    _turn, blocked_loop = running_child!(blocked_child)
    call_round!(blocked_loop, "r1", ["send", { to: @conversation.public_id, message: "done early" }])

    assert_equal Run::PARENT_WAITING, tool_result(blocked_loop, "r2t0")
    assert tool_error?(blocked_loop, "r2t0")
    assert_equal 0, rows_on(@conversation).where(origin: "agent").count, "nothing binds to the parked parent"
  end

  # ── status ───────────────────────────────────────────────────────────

  test "status is three facts: running or idle, the queue depth, who answers" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    call_round!(run, "r2", ["status", { to: "reviewer" }])
    assert_equal "conversation #{child.public_id} — idle; queue: 1 waiting; answered by @#{@agent.handle}.",
      tool_result(run, "r3t0"), "the brief waits; nothing runs yet"
    refute tool_error?(run, "r3t0")

    running_child!(child)
    call_round!(run, "r3", ["status", { to: child.public_id }], ["status", { to: "nobody" }])
    assert_equal "conversation #{child.public_id} — running; queue: 0 waiting; answered by @#{@agent.handle}.",
      tool_result(run, "r4t0")
    assert_equal format(Run::UNKNOWN, "nobody".inspect), tool_result(run, "r4t1")
    assert tool_error?(run, "r4t1")
  end

  # THE FOURTH FACT, only when it holds: a reply the addressee sent the caller waits in the CALLER's
  # own queue while the caller's turn runs — the addressee's queue is true and useless there. Counted
  # are the caller's pending, due rows the addressee sent: a steering row lands at the next boundary
  # anyway, and a row scheduled for later is not in the room yet.
  test "status says how many messages from the addressee wait for the caller, and says nothing when none do" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    reply!(child)
    stamped = ->(**fields) {
      Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
        host: @conversation, acting_user: @agent, entries: [{ "text" => "from the child" }],
        sender_conversation_public_id: child.public_id, **fields
      ))
    }
    assert_equal "pending", stamped.call.value.state
    call_round!(run, "r2", ["status", { to: "reviewer" }])
    assert_equal "conversation #{child.public_id} — idle; queue: 0 waiting; answered by @#{@agent.handle}. " \
      "1 message from it waits for you, delivered when you end your turn.", tool_result(run, "r3t0")

    call_round!(run, "r3", ["send", { to: "reviewer", message: MORE }])
    reply!(child)
    assert_equal "pending", stamped.call.value.state
    assert_equal "steering", stamped.call(delivery_mode: "steer").value.state
    assert_equal "pending", stamped.call(deliver_at: 1.hour.from_now.utc.floor).value.state
    call_round!(run, "r4", ["status", { to: "reviewer" }])
    assert_equal "conversation #{child.public_id} — idle; queue: 0 waiting; answered by @#{@agent.handle}. " \
      "2 messages from it wait for you, delivered when you end your turn.", tool_result(run, "r5t0")
    assert_equal [Run::QUEUED_FOR_YOU, Run::QUEUED_FOR_YOU_MANY],
      ["%d message from it waits for you, delivered when you end your turn.",
       "%d messages from it wait for you, delivered when you end your turn."]
  end

  # The child takes up what is queued for it and answers; its turn settles and the relay mails the
  # reply to the caller, whose turn is still running.
  def reply!(child)
    _turn, child_loop = running_child!(child)
    apply_via(attempt_for(child_loop, "r1"), sse_success("reviewed"))
    Runs::ConvergeTerminalSteps.call
    Runs::ScheduleReady.call(run_id: child_loop.id)
    Conversations::Turns::Converge.call
    Runs::Spawn::RelayJob.perform_now(child.id)
    clear_enqueued_jobs
  end

  # ── cancel ───────────────────────────────────────────────────────────

  test "cancel stops the child's reply and its derived requests; the owed reply still arrives marked canceled" do
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    child_turn, child_loop = running_child!(child)
    call_round!(child_loop, "r1", ["spawn", { prompt: "lint it", label: "linter" }])
    grandchild = Conversation.find_by!(spawn_node_id: loop_node(child_loop, "r2t0").id)
    grandchild_turn, grandchild_loop = running_child!(grandchild)

    assert_enqueued_with(job: Conversations::Turns::ConvergeJob) do
      call_round!(run, "r2", ["cancel", { to: "reviewer" }])
    end
    assert_equal Run.canceled_text(child), tool_result(run, "r3t0")
    refute tool_error?(run, "r3t0")
    settle_stopped_loops(child_loop, grandchild_loop)
    assert_equal %w[canceled canceled], [child_turn.reload.status, grandchild_turn.reload.status],
      "the tree: the child and the conversation it spawned"

    Runs::Spawn::RelayJob.perform_now(child.id)
    assert_empty rows_on(@conversation).where(origin: "child"), "mail waits for the canceller's final reply"
    finish_reply(run, "r3", "Stopped the child")
    Runs::ResultDelivery.call(run.reload)
    completion = loop_node(run, "r2t0").spawn_delegation
    assert_equal "failed", completion.status
    assert_equal "canceled", Runs::TaskResultProjection.call(completion).dig("structured_content", "status")
    mail = rows_on(@conversation).where(origin: "child").sole
    assert_equal Runs::TaskResultEnvelope.child_reply(call_key: "r2t0", status: "failed",
      conversation_public_id: child.public_id, body: completion.output_body.effective_text), mail.text,
      "the canceled worker is still reported through its original completion"

    # A CASCADE CANCEL OWES NOTHING BELOW THE CANCELLER: the grandchild's canceled reply was owed to
    # the child's turn, which the same stop canceled — it is stamped, never mailed, so it never
    # wakes the canceled child as a new turn.
    Runs::Spawn::RelayJob.perform_now(grandchild.id)
    assert_not_nil grandchild_turn.reload.relayed_at, "stamped as nothing owed"
    assert_empty rows_on(child).where(origin: "child"), "no mail on the canceled child"
    assert_equal 0, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id), "nothing wakes it"
    assert_equal 1, rows_on(@conversation).where(origin: "child").count,
      "the canceller receives the child's canceled result once after its final reply"
  end

  test "cancel of an idle conversation is a no-op sentence; of a read-level one, not_authorized" do
    peer = create_agent_member(display_name: "Reviewer", agent_identifier: "reviewer-1")
    readable = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: peer,
      access_default: "read")
    run = spawning_loop(label: "reviewer")
    child = child_of(run)
    call_round!(run, "r2", ["cancel", { to: "reviewer" }], ["cancel", { to: readable.public_id }])

    assert_equal format(Run::NOTHING_TO_CANCEL, child.public_id), tool_result(run, "r3t0")
    refute tool_error?(run, "r3t0")
    assert_equal 1, rows_on(child).count, "the queued brief is untouched"
    assert_equal format(Run::NOT_AUTHORIZED, readable.public_id), tool_result(run, "r3t1")
    assert tool_error?(run, "r3t1")
  end

  # ── the standalone loop ──────────────────────────────────────────────

  test "a standalone loop refuses all three verbs with the one sentence spawn minted" do
    tools = [Nexus::Tools::SEND, Nexus::Tools::STATUS, Nexus::Tools::CANCEL, READ_TOOL]
    run = seed(model("round1", "prompt" => "go", "tools" => tools))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    Runs::ScheduleReady.call(run_id: run.id)
    call_round!(run, "round1", ["send", { to: @conversation.public_id, message: "hi" }],
      ["status", { to: @conversation.public_id }], ["cancel", { to: @conversation.public_id }])

    assert_equal "send needs a conversation: this loop has none.", tool_result(run, "r1t0")
    assert_equal "status needs a conversation: this loop has none.", tool_result(run, "r1t1")
    assert_equal "cancel needs a conversation: this loop has none.", tool_result(run, "r1t2")
    assert %w[r1t0 r1t1 r1t2].all? { |key| tool_error?(run, key) }
    assert_equal Runs::Spawn::Run::NO_CONVERSATION, format(Run::NO_CONVERSATION, "spawn")
    assert_equal 0, rows_on(@conversation).count
  end
end
