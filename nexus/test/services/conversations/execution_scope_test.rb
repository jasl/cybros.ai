require "test_helper"

class Conversations::ExecutionScopeTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @speaker = Speakers::Resolve.member(account: @account, user: @human)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: Nexus::ToolRegistry.wire_names_in("nexus.memory").map do |name|
      Nexus::ToolRegistry.function_definition(name)
    end)
    @limit = { "bindings" => %w[conversation workspace speaker].map do |scope|
      { "name" => scope, "scope" => scope, "access" => (scope == "workspace" ? "read" : "read_write") }
    end }
    @agent.update!(memory_context_limit: @limit, conversation_reach: "subtree")
  end

  def context(conversation = @conversation, configuration: conversation.effective_memory_context, agent: @agent)
    MemoryDocuments::Context.new(workspace: @workspace, conversation: conversation, principal: @human,
      configuration: configuration, agent: agent)
  end

  def document(path, content, agent: @agent, speaker: @speaker)
    anchor = Scopes::Anchor.call(path: path, conversation: @conversation, workspace: @workspace,
      user: @human, agent: agent, speaker: speaker)
    result = MemoryDocuments::Write.call(anchor: anchor, content: content, expected: nil)
    assert_predicate result, :written?, result.outcome.to_s
    result.document
  end

  def seed_text(agent_run)
    agent_run.agent_run_tasks.find_by!(node_key: "r1").input_body.effective_text
  end

  test "one effective context governs management memory injection skills and tools" do
    @conversation.update!(memory_context: MemoryContext.capture(configuration: nil, speaker: @speaker))
    document("agent/private.md", "private Agent fact")
    document("user/private.md", "private Human fact")
    document("workspace/shared.md", "shared Workspace fact")
    document("speaker/preferences.md", "current Speaker fact")
    assert_equal %w[conversation workspace speaker], context.bindings.map(&:name)
    assert_equal :memory_read_only, context.resolve("workspace/new.md", authoring: true).refusal
    assert_equal :memory_scope_unavailable, context.resolve("agent/private.md").refusal
    assert_equal :memory_scope_unavailable, context.resolve("user/private.md").refusal
    assert_equal %w[speaker/preferences.md workspace/shared.md], context.listing.map(&:path)
    assert_equal @agent.public_id, context.projection[:bindings].last[:agent_public_id]
    assert_equal @speaker.public_id, context.projection[:bindings].last[:speaker_public_id]

    turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "remember")
    assert_includes seed_text(agent_run), "current Speaker fact"
    refute_includes seed_text(agent_run), "private Agent fact"
    refute_includes seed_text(agent_run), "private Human fact"
    assert_equal "subtree", agent_run.conversation_reach
    @agent.update!(memory_context_limit: nil, conversation_reach: nil)
    @conversation.reload.update!(memory_context: nil)
    assert_equal @speaker.public_id, agent_run.memory_context.fetch("bindings").last.fetch("speaker_public_id")
    assert_equal "subtree", agent_run.reload.conversation_reach

    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("tools", tool_calls: [
      { id: "write_shared", name: "memory_write", arguments: { path: "workspace/shared.md", content: "forbidden" }.to_json },
      { id: "write_speaker", name: "memory_write", arguments: { path: "speaker/preferences.md", content: "updated Speaker fact" }.to_json },
      { id: "read_private", name: "memory_read", arguments: { path: "agent/private.md" }.to_json },
    ]))
    %w[write_shared write_speaker read_private].each do |id|
      node = agent_run.agent_run_tasks.find_by!(tool_call_id: id)
      AgentRuns::MemoryJob.perform_now(node.id)
    end
    assert_includes agent_run.agent_run_tasks.find_by!(tool_call_id: "write_shared").output_body.effective_text, "memory_read_only"
    assert_includes agent_run.agent_run_tasks.find_by!(tool_call_id: "read_private").output_body.effective_text, "memory_scope_unavailable"
    assert_equal "updated Speaker fact", MemoryDocument.for_speaker(@agent.id, @speaker.id).sole.content
    assert_equal "shared Workspace fact", MemoryDocument.for_workspace(@workspace.id).sole.content
    assert_equal turn.active_variant.memory_context, agent_run.memory_context
  end

  test "missing management subject is unavailable while a generic input freezes its actual Speaker" do
    assert_equal :memory_scope_unavailable, context.resolve("speaker/preferences.md").refusal
    other = Speakers::Resolve.member(account: @account, user: users(:owner))
    document("speaker/preferences.md", "another Speaker", speaker: other)
    document("speaker/preferences.md", "this Speaker")
    _turn, agent_run = materialize_loop_reply!(@conversation, agent: @human, text: "remember")
    assert_equal @speaker.public_id, agent_run.memory_context.fetch("bindings").last.fetch("speaker_public_id")
    assert_includes seed_text(agent_run), "this Speaker"
    refute_includes seed_text(agent_run), "another Speaker"
    assert_equal :memory_scope_unavailable, context.resolve("speaker/preferences.md").refusal
  end

  test "prompt templates select persona independently of memory limits" do
    written = PromptDocuments::Write.call(anchor: { user: @human }, slot: "persona", content: "The person's prompt document.")
    assert_predicate written, :written?
    assert_equal :memory_scope_unavailable, context.resolve("user/private.md").refusal
    blocks = [
      { "type" => "slot", "slot" => "persona" },
      { "type" => "history" },
      { "type" => "input" },
    ]
    selected = Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human,
      declaring_profile: @agent, prompt: "hello", template: PromptTemplate.parse("blocks" => blocks))
    assert_includes selected.messages.flat_map { |message| message.parts.map(&:text) }, "The person's prompt document."

    excluded = Conversations::ContextAssembly.assemble(conversation: @conversation, principal: @human,
      declaring_profile: @agent, prompt: "hello", template: PromptTemplate.parse("blocks" => blocks.drop(1)),
      inline: [{ "slot" => "persona", "text" => "An inline persona override." }])
    assert_empty excluded.slots.versions
    assert_equal ["hello"], excluded.messages.flat_map { |message| message.parts.map(&:text) }
  end

  test "limits do not restore omitted roots and discard foreign conversation aliases" do
    other = Conversation.create!(workspace: @workspace, creating_user: @human)
    selected = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read" },
      { "name" => "foreign", "scope" => "conversation", "access" => "read_write", "conversation_public_id" => other.public_id },
      { "name" => "agent", "scope" => "agent", "access" => "read_write" },
    ] }
    @conversation.update!(memory_context: selected)
    assert_equal [{ "name" => "conversation", "scope" => "conversation", "access" => "read" }],
      @conversation.effective_memory_context.fetch("bindings")
  end

  test "spawn and send retain Speaker identity while rebinding to the receiving Agent" do
    _turn, source = materialize_loop_reply!(@conversation, agent: @human, text: "delegate")
    receiver = @account.users.create!(kind: :agent, role: :member, display_name: "Receiver",
      steward: users(:owner), agent_identifier: "receiver")
    receiver_speaker = Speakers::Resolve.member(account: @account, user: users(:owner))
    target = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: receiver,
      memory_context: MemoryContext.capture(configuration: nil, speaker: receiver_speaker))
    input = ConversationInput.new(host: target, authoring_user: @agent, answering_user: receiver,
      account: @account, origin: "agent", sender_run_public_id: source.public_id, speaker: @speaker)
    received = context(target, configuration: input.execution_memory_context, agent: receiver)
    assert_equal %w[conversation workspace speaker], received.bindings.map(&:name)
    anchor = received.resolve("speaker/preferences.md", authoring: true)
    assert_equal receiver, anchor.user
    assert_equal @speaker, anchor.speaker
    assert_equal :memory_scope_unavailable, received.resolve("agent/private.md").refusal
    assert_equal :memory_read_only, received.resolve("workspace/private.md", authoring: true).refusal

    result = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: @workspace, creating_user: @agent, title: "child", metadata: {}, billing_subject: nil,
      answering_user_public_id: receiver.public_id, parent: @conversation,
      spawn_node: source.agent_run_tasks.first, conversation_reach: source.conversation_reach
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    child = result.value
    assert_equal "subtree", child.conversation_reach
    child_context = context(child, agent: receiver)
    assert_equal receiver, child_context.resolve("speaker/preferences.md").user
    assert_equal @speaker, child_context.resolve("speaker/preferences.md").speaker
    assert_equal child, child_context.resolve("conversation/notes.md").conversation
  end

  test "raw standalone work freezes memory and reach before any model environment exists" do
    standalone = seed(ask("question", "prompt" => "Continue?"), creating_user: @agent, prompt_mechanism: "raw")
    assert_nil standalone.agent_run_tasks.first.operation_context
    assert_equal "subtree", standalone.conversation_reach
    assert_equal %w[conversation workspace speaker], standalone.memory_context.fetch("bindings").map { |entry| entry.fetch("scope") }
    @agent.update!(memory_context_limit: nil, conversation_reach: nil)
    grow!(standalone, model("later", "prompt" => "history", "tools" => [Nexus::ToolRegistry.function_definition("session_search")]))
    assert_equal "subtree", standalone.reload.conversation_reach
    assert_equal :memory_scope_unavailable, context(nil, configuration: standalone.memory_context).resolve("agent/private.md").refusal
  end

  test "Speaker documents and Agent documents have independent capacity" do
    @agent.update!(memory_context_limit: nil)
    MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR.times { |index| document("agent/note-#{index}.md", "private") }
    MemoryDocument::MAX_DOCUMENTS_PER_ANCHOR.times { |index| document("speaker/note-#{index}.md", "about this speaker") }
    assert_equal 64, MemoryDocument.for_user(@agent.id).count
    assert_equal 64, MemoryDocument.for_speaker(@agent.id, @speaker.id).count
    anchor = Scopes::Anchor.call(path: "speaker/overflow.md", agent: @agent, speaker: @speaker)
    assert_equal :memory_full, MemoryDocuments::Write.call(anchor: anchor, content: "full", expected: nil).outcome
    another = Speakers::Resolve.member(account: @account, user: users(:owner))
    assert_predicate document("speaker/notes.md", "new speaker", speaker: another), :persisted?
  end
  test "a limited profile can create a host before an input supplies its Speaker" do
    outcome = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: @workspace, creating_user: @human, answering_user_public_id: @agent.public_id,
      title: "generic", metadata: {}, billing_subject: nil
    ))
    assert_predicate outcome, :accepted?, outcome.outcome.to_s
    assert_equal :memory_scope_unavailable, context(outcome.value).resolve("speaker/notes.md").refusal
  end

  test "skill catalogs use the same limited roots as document reads" do
    configuration = MemoryContext.capture(configuration: @conversation.effective_memory_context, speaker: @speaker)
    %w[agent user workspace speaker].each do |scope|
      anchor = Scopes::Anchor.call(path: "#{scope}/skills/#{scope}-skill", user: @human,
        workspace: @workspace, agent: @agent, speaker: @speaker)
      written = MemoryDocuments::Write.call(anchor: anchor, content: "#{scope} instructions", description: "A #{scope} skill", expected: nil)
      assert_predicate written, :written?
    end
    catalog = AgentRuns::Skills::Catalog.for(tools: [Nexus::Tools::SKILL], address: nil,
      context: context(configuration: configuration))
    assert_equal %w[workspace-skill speaker-skill], catalog.map(&:name)
    assert_equal %w[workspace speaker], catalog.map(&:source)
  end

  test "regeneration and completion mail retain the initiating Speaker after the host selects another" do
    turn, original = materialize_loop_reply!(@conversation, agent: @human, text: "remember")
    frozen_context = original.memory_context
    AgentRuns::Transition.agent_run(original, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call
    other = Speakers::Resolve.member(account: @account, user: users(:owner))
    @conversation.reload.update!(memory_context: MemoryContext.capture(configuration: nil, speaker: other))
    callback = ConversationInput.new(host: @conversation, origin: "task_result", account: @account,
      authoring_user: @human, answering_user: @agent, sender_run_public_id: original.public_id)
    assert_equal frozen_context, callback.execution_memory_context
    assert_equal "subtree", callback.execution_conversation_reach
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: "dev", model_ref: "mock-priced", reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal frozen_context, result.value.memory_context
    assert_equal frozen_context, result.value.agent_run.memory_context
    assert_equal "subtree", result.value.agent_run.conversation_reach
  end
end
