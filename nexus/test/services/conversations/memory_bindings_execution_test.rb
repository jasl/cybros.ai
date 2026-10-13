require "test_helper"

class Conversations::MemoryBindingsExecutionTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @shared = Conversation.create!(workspace: @workspace, creating_user: @human)
    @configuration = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      { "name" => "group", "scope" => "conversation", "access" => "read_write", "conversation_public_id" => @shared.public_id },
    ] }
    write(@shared, "conversation/shared.md", "shared database fact")
    anchor = Scopes::Anchor.call(path: "user/private.md", user: @human)
    result = MemoryDocuments::Write.call(anchor: anchor, content: "unselected user fact", expected: nil)
    assert_predicate result, :written?
    @conversation.update!(memory_context: @configuration)
    declare_tools!(@agent, tools: Nexus::ToolRegistry.wire_names_in("nexus.memory").map do |name|
      Nexus::ToolRegistry.function_definition(name)
    end)
  end

  def write(conversation, path, content)
    result = Conversations::Memory::Apply.write(conversation: conversation, path: path,
      content: content, by: @human, expected: nil)
    assert_predicate result, :accepted?, result.outcome.to_s
  end

  def open_turn
    turn, loop = materialize_loop_reply!(@conversation, agent: @human, text: "use the selected memory")
    schedule_loop!(loop)
    [turn, loop]
  end

  def seed_text(loop)
    loop.agent_run_tasks.find_by!(node_key: "r1").content_bodies.find_by!(role: "input")
      .content_body_entries.map { |entry| entry.content_fragment.payload.to_json }.join
  end

  def settle(turn, loop)
    AgentRuns::Transition.agent_run(loop, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
  end

  def deliver_brief(child, source)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: child, acting_user: @agent, kind: "direct_reply", entries: [{ "text" => "use the selected memory" }],
      sender_conversation_public_id: @conversation.public_id, run_public_id: source.public_id,
      task_key: source.agent_run_tasks.find_by!(node_key: "r1").node_key,
      provider_id: "dev", model_ref: "mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child.reload.active_turn.active_variant.agent_run
  end

  test "materialization freezes selected paths for injection and later tools" do
    turn, loop = open_turn
    assert_equal @configuration, turn.active_variant.memory_context
    assert_equal @configuration, loop.memory_context
    assert_includes seed_text(loop), "group/shared.md"
    assert_includes seed_text(loop), "shared database fact"
    refute_includes seed_text(loop), "unselected user fact"
    @conversation.reload.update!(memory_context: { "bindings" => [] })

    run_loop_round!(loop, sse_success("reading", tool_calls: [
      { id: "shared_read", name: "memory_read", arguments: { path: "group/shared.md" }.to_json },
    ]))
    call = loop.agent_run_tasks.find_by!(tool_call_id: "shared_read")
    AgentRuns::MemoryJob.perform_now(call.id)
    assert_equal "completed", call.reload.status
    refute call.output_summary["is_error"]
    assert_equal "shared database fact", call.output_body.effective_text
    scope = Executors::Inbox.scope_of(call).fetch(:bindings)
    assert_equal %w[conversation group], scope.map { |binding| binding.fetch(:name) }
    assert_equal @shared.public_id, scope.last.fetch(:conversation_public_id)
  end

  test "regeneration reassembly preserves the source memory configuration" do
    turn, loop = open_turn
    settle(turn, loop)
    @conversation.reload.update!(memory_context: { "bindings" => [] })
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: "dev", model_ref: "mock-priced", reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal @configuration, result.value.memory_context
    assert_equal @configuration, result.value.agent_run.memory_context
    assert_includes seed_text(result.value.agent_run), "shared database fact"
    refute_includes seed_text(result.value.agent_run), "unselected user fact"
  end

  test "kernel completion mail freezes the initiating execution while ordinary peer mail uses the receiver" do
    turn, loop = open_turn
    settle(turn, loop)
    @conversation.reload.update!(memory_context: { "bindings" => [] })
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @human, entries: [{ "text" => "background result" }],
      origin: "task_result", sender_conversation_public_id: @conversation.public_id,
      run_public_id: loop.public_id, task_key: "background", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text", answering_user_public_id: @agent.public_id
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    mailed = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
    assert_equal @configuration, mailed.memory_context
    assert_includes seed_text(mailed), "shared database fact"

    peer = ConversationInput.new(host: @conversation, origin: "agent", sender_run_public_id: loop.public_id)
    assert_equal({ "bindings" => [] }, peer.execution_memory_context)
    orphaned = ConversationInput.new(host: @conversation, origin: "task_result", sender_run_public_id: SecureRandom.uuid_v7)
    assert_equal({ "bindings" => [] }, orphaned.execution_memory_context)
  end

  test "spawn inherits explicit anchors while its relative conversation becomes the child" do
    _turn, loop = open_turn
    @conversation.reload.update!(memory_context: { "bindings" => [] })
    source = loop.agent_run_tasks.find_by!(node_key: "r1")
    result = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: @workspace, creating_user: @agent, title: "child", metadata: {}, billing_subject: nil,
      parent: @conversation, spawn_node: source
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    child = result.value
    assert_equal @configuration, child.memory_context
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: child,
      principal: @agent, configuration: child.memory_context, agent: child.answering_agent)
    assert_equal child, context.resolve("conversation/own.md").conversation
    assert_equal @shared, context.resolve("group/shared.md").conversation
    assert_equal :memory_scope_unavailable, context.resolve("user/private.md").refusal

    child_run = deliver_brief(child, loop)
    assert_equal @configuration, child_run.memory_context
    assert_includes seed_text(child_run), "shared database fact"
  end

  test "spawn preserves distinct Speaker aliases and their access modes through first execution" do
    first = Speakers::Resolve.member(account: @account, user: @human)
    second = Speakers::Resolve.member(account: @account, user: users(:owner))
    configuration = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      { "name" => "speaker", "scope" => "speaker", "access" => "read", "speaker_public_id" => first.public_id },
      { "name" => "colleague", "scope" => "speaker", "access" => "read_write", "speaker_public_id" => second.public_id },
    ] }
    @conversation.update!(memory_context: configuration)
    _turn, source = open_turn
    result = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: @workspace, creating_user: @agent, title: "child", metadata: {}, billing_subject: nil,
      parent: @conversation, spawn_node: source.agent_run_tasks.find_by!(node_key: "r1")
    ))
    assert_predicate result, :accepted?, result.outcome.to_s

    child = result.value
    child_run = deliver_brief(child, source)
    assert_equal configuration, child_run.memory_context
    context = MemoryDocuments::Context.new(workspace: @workspace, conversation: child,
      principal: @agent, configuration: child_run.memory_context, agent: @agent)
    assert_equal :memory_read_only, context.resolve("speaker/notes.md", authoring: true).refusal
    writable = context.resolve("colleague/notes.md", authoring: true)
    assert_predicate writable, :resolved?
    assert_equal second, writable.speaker
  end
end
