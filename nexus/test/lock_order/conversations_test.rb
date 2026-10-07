require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class ConversationsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "a side snapshot descends conversation, source run, retained fragments and cursor" do
    human = users(:member)
    agent = users(:agent)
    declare_tools!(agent)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human,
      answering_user: agent)
    _turn, run = materialize_loop_reply!(conversation, agent: human, text: "show progress")
    schedule_loop!(run)

    sequences = assert_ladder_order("side snapshot") do
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: conversation.reload, turn_public_id: nil, variant_public_id: nil,
        acting_user: human, title: nil, side: true
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    seen = sequences.flatten
    %w[conversations agent_runs content_fragments conversation_event_cursors].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below)
    end
  end

  # The turn converger's loop frontier: conversation first, then the loop, then the cursor its
  # settle narrates on — the order every loop-side path also keeps below the loop, so the two never
  # cycle.
  test "the turn converger's settle descends conversation, loop, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention",
      attention_reason: "halt_failure")

    sequences = assert_ladder_order("turn converger settle") do
      assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[conversations agent_runs conversation_event_cursors]
    assert_equal "failed", seam.turn.reload.status
  end

  # The REPLACE arm is the one site of `replaced` because no statement order inside ApplyNext passes
  # this guard: the stop locks the loop's invocations, ranked below the successor's own loop and
  # nodes.
  test "the turn converger's replace descends conversation, loop, invocation" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    appended = grow(seam.agent_run, model("step", "prompt" => "go"))
    assert_predicate appended, :applied?
    AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    AgentRuns::Transition.agent_run(seam.agent_run, status: "needs_attention",
      attention_reason: "halt_failure")
    Conversations::Turns::Converge.call
    actor = Speakers::Resolve.member(account: account, user: human)
    ConversationTurn.create!(
      account: account, conversation: conversation.reload, position: conversation.timeline_position_head,
      kind: "message", role: "user", status: "completed",
      speaker: actor, control_owner_user: human
    )

    sequences = assert_ladder_order("turn converger replace") do
      assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[conversations agent_runs model_invocations conversation_event_cursors]
    assert_equal "replaced", seam.agent_run.reload.failure_reason
  end

  # The drain: the first explicit lock on `conversation_inputs`, taken under the loop lock at the
  # peek, before the fragments the sealed request writes and the cursor the landing narrates on.
  test "the drain descends loop, input rows, fragments, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(model("step", "prompt" => "go"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    agent_run = created.agent_run
    assert_predicate loop_input!(agent_run, acting_user: human, text: "steer"), :accepted?
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: human
    ))

    sequences = assert_ladder_order("drain") do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end

    seen = sequences.flatten
    assert_operator seen.index("agent_runs"), :<, seen.index("conversation_inputs")
    assert_operator seen.index("conversation_inputs"), :<, seen.index("content_fragments")
    assert_operator seen.index("content_fragments"), :<, seen.index("conversation_event_cursors")
    assert_equal 0, agent_run.conversation_inputs.count, "the row landed"
  end

  # The Destroy-vs-Consume pair, in the guard's terms: the conversation door holds conversation →
  # input row and the drain holds loop → input row, both in ladder order, so the row lock is the
  # only thing they share and the database's order has no cycle to complete.
  test "the conversation door and the loop drain both descend to the input row" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    appended = grow(seam.agent_run, model("step", "prompt" => "go"))
    assert_predicate appended, :applied?
    accept = lambda do |text|
      Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: human, kind: "message", role: "user",
        entries: [{ "text" => text }], visible_in_context: true, delivery_mode: "steer",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil
      ))
    end
    doomed = accept.call("cancel me").value
    assert_predicate accept.call("land me"), :accepted?

    door = assert_ladder_order("conversation door") do
      result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: conversation, acting_user: human, input_public_id: doomed.public_id
      ))
      assert_predicate result, :accepted?
    end
    drain = assert_ladder_order("loop drain") do
      AgentRuns::ScheduleReady.call(agent_run_id: seam.agent_run.id)
    end

    door_seen = door.flatten
    assert_operator door_seen.index("conversations"), :<, door_seen.index("conversation_inputs")
    assert_not_includes door_seen, "agent_runs", "the door never takes the loop"
    drain_seen = drain.flatten
    assert_operator drain_seen.index("agent_runs"), :<, drain_seen.index("conversation_inputs")
    assert_not_includes drain_seen, "conversations", "the drain never takes the conversation"
  end

  test "guarded steer cancellation descends conversation, target loop, input, cursor" do
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: human, kind: "message", role: "user",
      entries: [{ "text" => "only this execution" }], delivery_mode: "steer",
      visible_in_context: true, context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      expected_steering_run_public_id: seam.agent_run.public_id,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate accepted, :accepted?

    sequences = assert_ladder_order("guarded steer cancellation") do
      result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: conversation, acting_user: human, input_public_id: accepted.value.public_id
      ))
      assert_predicate result, :accepted?
    end

    seen = sequences.flatten
    %w[conversations agent_runs conversation_inputs conversation_event_cursors].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below),
        "the delete descends #{above} before #{below}: #{seen.inspect}"
    end
    assert_equal 0, conversation.conversation_inputs.count
  end

  # THE DOOR WITH A PICTURE: the conversation door pins the uploads a message binds `FOR KEY SHARE`
  # inside its lock section, and the body writer it then enters locks the input row (its owner) and
  # the fragments. `content_uploads`' rank was placed from the door's code order ("after host →
  # input row") until this flow was driven; the captured stream read host → uploads → input row →
  # fragments — the create composes the message before the body writer locks the fresh row — so the
  # rank moved above `conversation_inputs` and the edit door pins before it locks the row it edits,
  # the same order.
  test "the conversation door pins the pictures it binds before the row it binds them to" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    create_run_backed_turn(conversation: conversation, acting_user: human)
    picture = create_content_upload(account: account)

    created = assert_ladder_order("conversation door with a picture") do
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: human, kind: "message", role: "user",
        entries: [{ "text" => "look at this" }], attachments: [picture.public_id],
        visible_in_context: true, delivery_mode: "queue",
        context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?
      @queued = result.value
    end
    created_seen = created.flatten
    assert_includes created_seen, "content_uploads", "the door pins the picture it binds"
    %w[conversations content_uploads conversation_inputs content_fragments].each_cons(2) do |above, below|
      assert_operator created_seen.index(above), :<, created_seen.index(below),
        "the create descends #{above} before #{below}: #{created_seen.inspect}"
    end

    edited = assert_ladder_order("conversation door edit with a picture") do
      result = Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(
        host: conversation, input_public_id: @queued.public_id, acting_user: human,
        expected_lock_version: nil, entries: [{ "text" => "look again" }], attachments: [picture.public_id],
        visible_in_context: nil, context_mode: nil, context_options: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?
    end
    edited_seen = edited.flatten
    %w[conversations content_uploads conversation_inputs content_fragments].each_cons(2) do |above, below|
      assert_operator edited_seen.index(above), :<, edited_seen.index(below),
        "the edit descends #{above} before #{below}: #{edited_seen.inspect}"
    end
    assert_not_includes edited_seen, "agent_runs", "the door never takes the loop"
  end

  # Kernel mail: the writer runs in its own job because the input door holds the conversation and
  # the quiescence site holds the loop — the inverse of the ladder if one ran under the other. The
  # mail descends from the recipient conversation to its source loop to serialize the stop check,
  # then creates the input and its body. The tip's stamp remains a guarded write.
  test "kernel mail locks its source below the conversation and above the input body" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: seam.agent_run, origin: "kernel",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "bg", name: "shell", detached: true)],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?
    AgentRunTask.where(agent_run_id: seam.agent_run.id, node_key: "bg")
      .update_all(status: "completed", completed_at: Time.current)
    AgentRuns::Transition.agent_run(seam.agent_run, delivered_at: Time.current)

    sequences = assert_ladder_order("kernel mail") do
      assert_equal [:delivered], AgentRuns::ResultDelivery.call(seam.agent_run.reload)
    end

    seen = sequences.flatten
    %w[conversations agent_runs conversation_inputs content_fragments conversation_event_cursors].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below), "mail must descend #{above} before #{below}"
    end
    assert_equal 1, seen.count("agent_runs"), "mail locks its source once, before writing any body or event"
    assert_equal 1, conversation.conversation_inputs.count
    assert_not_nil seam.agent_run.agent_run_tasks.find_by!(node_key: "bg").result_delivered_at
  end

  # SPAWN: the child's create takes no explicit lock; the await's append holds the parent LOOP; the
  # brief's door holds the CHILD conversation followed by its source loop; the call's settle holds the loop again — separate
  # transactions, never a conversation under the loop or the loop under a conversation's event
  # cursor. ONE transaction around the three would descend cursor → loop against the ladder, which
  # is why the await is appended BEFORE the brief (the child cannot reply before its brief) and the
  # child row is minted first as the recovery key.
  test "a spawn descends the parent loop and the child conversation in separate transactions" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    agent = users(:agent)
    parent = Conversation.create!(workspace: workspaces(:shared), creating_user: human, answering_user: agent)
    seam = create_run_backed_turn(conversation: parent, acting_user: human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: seam.agent_run, origin: "model",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "r1t0", name: "spawn",
        input: { "prompt" => "review the models", "wait" => true })],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?
    call = seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0")
    AgentRunTask.where(id: call.id).update_all(status: "running", started_at: Time.current,
      await_started_at: Time.current)

    sequences = assert_ladder_order("spawn") do
      assert_equal :applied, AgentRuns::Spawn::Run.call(node: call.reload)
    end

    mixed = sequences.select { |sequence| sequence.include?("conversations") && sequence.include?("agent_runs") }
    assert_equal 1, mixed.length, "only the brief's door locks a recipient conversation and its source together"
    assert_equal "conversations", mixed.sole.first
    assert_operator mixed.sole.index("agent_runs"), :<, mixed.sole.index("conversation_inputs")
    assert sequences.any? { |sequence| sequence.first == "agent_runs" && !sequence.include?("conversations") },
      "the await's append and brief's door retain separate transactions"
    child = Conversation.find_by!(spawn_node_id: call.id)
    assert_equal parent, child.parent_conversation
    assert_equal 1, child.conversation_inputs.count
    await = seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0-spawn-1")
    assert_equal ["queued", true], [await.status, await.resolution_token.present?],
      "the kernel-held await is appended tokened; the scheduler parks it `dispatched` later"
  end

  # THE CHILD-REPLY RELAY: two paths, two transactions. The await path holds the parent LOOP, then
  # the await it settles, then the narration cursor — with the turn's relay stamp inside the same
  # transaction (conversation_turns is never explicitly locked, so the stamp is invisible here and
  # pinned by spawn_relay_test's torn-stamp case). The mail path holds the parent CONVERSATION and
  # its source loop, then the input body and cursor — kernel mail's own shape.
  def spawned_child_with_a_reply(wait:)
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    agent = users(:agent)
    parent = Conversation.create!(workspace: workspaces(:shared), creating_user: human, answering_user: agent)
    seam = create_run_backed_turn(conversation: parent, acting_user: human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: seam.agent_run, origin: "model",
      steps: [AgentRuns::Tasks::Step::Tool.new(key: "r1t0", name: "spawn",
        input: { "prompt" => "review the models", "wait" => wait })],
      tip: AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH)
    ))
    assert_predicate appended, :applied?
    call = seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0")
    AgentRunTask.where(id: call.id).update_all(status: "running", started_at: Time.current,
      await_started_at: Time.current)
    assert_equal :applied, AgentRuns::Spawn::Run.call(node: call.reload)
    AgentRunTask.where(agent_run_id: seam.agent_run.id, node_key: "r1t0-spawn-1")
      .update_all(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
    child = Conversation.find_by!(spawn_node_id: call.id)
    actor = Speakers::Resolve.member(account: account, user: agent)
    turn = ConversationTurn.create!(
      account: account, conversation: child, position: child.timeline_position_head,
      kind: "direct_reply", role: "assistant", status: "completed", origin: "agent",
      sender_conversation_public_id: parent.public_id,
      sender_run_public_id: child.conversation_inputs.sole.sender_run_public_id,
      sender_task_key: child.conversation_inputs.sole.sender_task_key,
      speaker: actor, control_owner_user: agent
    )
    [parent, seam, child, turn]
  end

  test "the relay's await path descends loop, task, cursor and never the conversation" do
    parent, seam, child, turn = spawned_child_with_a_reply(wait: true)

    sequences = assert_ladder_order("relay (await)") do
      assert_equal 1, AgentRuns::Spawn::Relay.call(conversation_id: child.id)[:relayed]
    end

    seen = sequences.flatten
    assert_operator seen.index("agent_runs"), :<, seen.index("agent_run_tasks")
    assert_operator seen.index("agent_run_tasks"), :<, seen.index("conversation_event_cursors")
    assert_not_includes seen, "conversations", "the await path takes no conversation lock"
    assert_equal "completed", seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0-spawn-1").status
    assert_not_nil turn.reload.relayed_at
    assert_equal 0, parent.conversation_inputs.count
  end

  test "the relay's mail path checks its source below the parent conversation and above the body" do
    parent, _seam, child, turn = spawned_child_with_a_reply(wait: false)

    sequences = assert_ladder_order("relay (mail)") do
      assert_equal 1, AgentRuns::Spawn::Relay.call(conversation_id: child.id)[:relayed]
    end

    seen = sequences.flatten
    %w[conversations agent_runs conversation_inputs content_fragments conversation_event_cursors].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below), "reply mail must descend #{above} before #{below}"
    end
    assert_equal 1, seen.count("agent_runs"), "the source check happens once before the mail is written"
    assert_equal 1, parent.conversation_inputs.count
    assert_not_nil turn.reload.relayed_at
  end

  test "a late child reply releases the await lock before mailing the reply" do
    parent, seam, child, turn = spawned_child_with_a_reply(wait: true)
    await = seam.agent_run.agent_run_tasks.find_by!(node_key: "r1t0-spawn-1")

    travel_to(await.deadline_at + 1.second) do
      sequences = assert_ladder_order("relay (expiry then mail)") do
        assert_equal 1, AgentRuns::Spawn::Relay.call(conversation_id: child.id)[:relayed]
      end

      expiry = sequences.find { |tables| tables.include?("agent_run_tasks") }
      mail = sequences.find { |tables| tables.include?("conversations") }
      refute_nil expiry, "expiry owns the loop and its await"
      refute_nil mail, "mail owns the recipient conversation"
      assert_not_includes expiry, "conversations", "expiry releases its loop before the mail takes the conversation"
      assert_operator sequences.index(expiry), :<, sequences.index(mail), "expiry and mail commit in separate transactions"
      assert_operator mail.index("conversations"), :<, mail.index("agent_runs")
    end

    assert_equal "timed_out", await.reload.status
    assert_equal 1, parent.conversation_inputs.count
    assert_not_nil turn.reload.relayed_at
  end

  # A declined direct reply its answerer's fallback re-asks: the converger's conversation lock, the
  # declined invocation it stamps, the new sample's sealed request below both, and the cursor both
  # narrations append on last — the reply frontier's own order, with no new edge.
  test "the reply converger's fallback descends conversation, invocation, fragments, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    agent = users(:agent)
    declared = Users::DeclareConfiguration.call(user: agent, tool_definitions: [], approval_mode: nil,
      approval_rules: nil, prompt_mechanism: nil, prompt_template: nil, compaction_policy: nil,
      fallback_model: "dev/mock-unmetered")
    assert_equal :declared, declared.outcome
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human, answering_user: agent)
    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: human, kind: "direct_reply", role: "user",
      entries: [{ "text" => "go" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate accepted, :accepted?
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    declined = ModelInvocation.find_by!(conversation: conversation)
    declined.with_lock { declined.terminalize(status: "completed", finish_quality: "refused", refusal_category: "cyber") }

    sequences = assert_ladder_order("reply converger fallback") do
      assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    end

    seen = sequences.flatten
    assert_operator seen.index("conversations"), :<, seen.index("model_invocations")
    assert_operator seen.index("model_invocations"), :<, seen.index("content_fragments")
    assert_operator seen.index("content_fragments"), :<, seen.index("conversation_event_cursors")
    assert_equal "fallback", ConversationTurnVariant.where(model_invocation: ModelInvocation.order(:id).last).sole.source
  end

  # Materialization of a tool-bearing reply: the drain holds the conversation, the seed batch takes
  # the NEWBORN loop's row through the append door, the sealed entries pin their fragments, and the
  # narration cursor comes last. No other loop lock is ever taken here: a predecessor's loop is the
  # converger's REPLACE arm to stop.
  test "materialization descends conversation, the new loop, fragments, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    agent = users(:agent)
    declared = Users::DeclareConfiguration.call(user: agent,
      tool_definitions: [{ "type" => "function",
                           "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }],
      approval_mode: "bypass", approval_rules: nil, prompt_mechanism: nil, prompt_template: nil,
      compaction_policy: nil
    )
    assert_equal :declared, declared.outcome
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: agent)
    accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: conversation, acting_user: agent, kind: "direct_reply", role: "user",
      entries: [{ "text" => "go" }], visible_in_context: true, delivery_mode: "queue",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate accepted, :accepted?

    sequences = assert_ladder_order("materialization") do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: conversation.id)
      assert_predicate result, :accepted?
    end

    seen = sequences.flatten
    assert_operator seen.index("conversations"), :<, seen.index("agent_runs")
    assert_operator seen.index("agent_runs"), :<, seen.index("content_fragments")
    assert_operator seen.index("content_fragments"), :<, seen.index("conversation_event_cursors")
    agent_run = AgentRun.sole
    assert_equal "running", agent_run.status
    assert_equal conversation, agent_run.conversation
  end
end
