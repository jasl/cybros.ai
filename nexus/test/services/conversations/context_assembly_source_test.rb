require "test_helper"

# THE SOURCE: what the blocks read from — the room and, when there is one, the conversation. A
# standalone loop has none: history is empty, memory is the workspace's and the creator's `user/`
# rung under the conversation-less header, the `character` slot is the room's and `{{workspace}}`
# the room's name — the same block classes, no second assembly path.
class Conversations::ContextAssemblySourceTest < ActiveSupport::TestCase
  Source = Conversations::ContextAssembly::Source

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @owner = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    # A conversation in the same room: its own rows must never reach a
    # standalone source, its workspace's must.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def write_memory!(path, content, by: @human)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by), conversation: @conversation, path: path, content: content, by: by)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  test "a conversation is its own source and a standalone source is the room alone" do
    source = Source.of(@conversation)
    assert_equal @workspace, source.workspace
    assert_equal @conversation, source.conversation
    assert_equal @conversation.id, source.conversation_id
    refute_predicate source, :standalone?
    assert_same source, Source.of(source), "a source passes through"

    standalone = Source.standalone(@workspace)
    assert_equal @workspace, standalone.workspace
    assert_nil standalone.conversation
    assert_nil standalone.conversation_id
    assert_nil standalone.timeline
    assert_predicate standalone, :standalone?
    assert_equal @agent, standalone.memory_principal(@agent), "the creator's own rung: no spawned-child rule without a conversation"
    assert_raises(ArgumentError) { Source.of(nil) }
  end

  test "history on a standalone source is empty, never a timeline read" do
    selection = Conversations::ContextAssembly::ChatHistory.call(conversation: Source.standalone(@workspace))
    assert_empty selection.segments
    assert_equal 0, selection.selected_count
    assert_equal 0, selection.skipped_count
    assert_nil selection.skipped_reason
    assert_equal 0, selection.compacted_count
  end

  test "conversation kind follows durable public identity without loading a reaped parent or schedule" do
    child = Conversation.new(workspace: @workspace, parent_conversation_public_id: SecureRandom.uuid_v7)
    scheduled = Conversation.new(workspace: @workspace, parent_conversation_public_id: SecureRandom.uuid_v7,
      schedule_public_id: SecureRandom.uuid_v7)
    side = Conversation.new(workspace: @workspace, side: true)
    sources = [[Source.standalone(@workspace), "standalone"], [Source.of(@conversation), "conversation"],
      [Source.of(child), "child"], [Source.of(scheduled), "scheduled"], [Source.of(side), "side"]]

    assert_nil child.spawn_node_id
    assert_nil child.parent_conversation_id
    assert_nil scheduled.schedule_id
    assert_no_queries do
      sources.each { |source, kind| assert_equal kind, source.conversation_kind }
    end
  end

  # The header is model-facing text: the measured one names the
  # conversation, the standalone one cannot — the variant is the smallest
  # edit of the measured sentence.
  test "memory on a standalone source is the workspace's and the principal's rung under the conversation-less header" do
    write_memory!("workspace/shared.md", "workspace fact")
    travel 1.minute
    write_memory!("conversation/private.md", "conversation fact")
    travel 1.minute
    write_memory!("user/mine.md", "user fact", by: @owner)

    block = Conversations::ContextAssembly::MemoryBlock.call(conversation: Source.standalone(@workspace), principal: @agent)
    assert_equal 2, block.included
    assert_equal 0, block.omitted
    text = block.segments.sole.text
    assert_equal "user", block.segments.sole.role
    assert text.start_with?(Conversations::ContextAssembly::MemoryBlock::STANDALONE_HEADER), text
    refute_includes text, "conversation", "no conversation is named and none is read"
    assert_includes text, "## user/mine.md\nuser fact", "the creator's controlling Human's rung"
    assert_includes text, "## workspace/shared.md\nworkspace fact"
    refute_includes text, "conversation fact", "the room's conversations' own rows are not the loop's"
    assert_operator text.index("user/mine.md"), :<, text.index("workspace/shared.md"), "newest first across the scopes"

    conversational = Conversations::ContextAssembly::MemoryBlock.call(conversation: @conversation, principal: @owner)
    assert_equal 3, conversational.included, "the conversation's source still reads all three"
    assert conversational.segments.sole.text.start_with?(Conversations::ContextAssembly::MemoryBlock::HEADER)
  end

  test "memory on a standalone source is silent under a memory_read override" do
    write_memory!("workspace/shared.md", "workspace fact")
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    set = Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace, by: @owner, lock_version: @workspace.reload.lock_version,
      overrides: { "nexus.memory" => provider.public_id }
    )
    assert_equal :updated, set.outcome

    block = Conversations::ContextAssembly::MemoryBlock.call(conversation: Source.standalone(@workspace), principal: @agent)
    assert_predicate block, :empty?
  end

  test "the slots and the macro sources read the room through a standalone source" do
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "The room is {{workspace}}.")
    written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
      content: "I am {{agent}} in {{conversation_kind}}.", role: "developer")
    assert_predicate written, :written?
    PromptDocuments::Write.call(anchor: { user: @owner }, slot: "persona", content: "I am {{user}}.", role: "user")

    source = Source.standalone(@workspace)
    sources = Conversations::ContextAssembly::MacroSources.call(conversation: source, principal: @agent, declaring_profile: @agent)
    assert_equal @workspace.name, sources.fetch("workspace")
    assert_equal @agent.display_name, sources.fetch("agent")
    assert_equal @owner.display_name, sources.fetch("user"), "the creator's controlling Human"
    assert_equal "standalone", sources.fetch("conversation_kind")

    blocks = Conversations::ContextAssembly::SlotBlocks.call(conversation: source, principal: @agent, declaring_profile: @agent)
    assert_equal [["developer", "I am #{@agent.display_name} in standalone."], ["system", "The room is #{@workspace.name}."],
                  ["user", "I am #{@owner.display_name}."]],
      blocks.segments.map { |segment| [segment.role, segment.text] }
  end
end
