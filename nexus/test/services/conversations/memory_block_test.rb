require "test_helper"

# THE CONVERSATION PLANE'S ONLY MEMORY READER. A direct_reply is one model
# call with no tools, so there is no `memory_read` here — injection is not
# an alternative to a read tool on this plane, it is the whole mechanism.
class Conversations::MemoryBlockTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    # Answered by the agent: the engine of every reply head here is the agent's.
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def write!(path, content, by: @human)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by),
      conversation: @conversation, path: path, content: content, by: by
    )
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # `principal` is the User whose turn this is — the block renders the
  # `user/` rung of ITS controlling Human, never the conversation's creator's.
  def assemble(prompt: "now what", principal: @human)
    Conversations::ContextAssembly.assemble(
      conversation: @conversation.reload, prompt: prompt, principal: principal
    )
  end

  test "no memory means no block at all, not an empty one" do
    assembled = assemble
    assert_predicate assembled.memory, :empty?
    assert_equal ["now what"], assembled.messages.map { |m| m.parts.first.text }
  end

  test "memory LEADS — ahead of history, where the prefix stays warm" do
    write!("workspace/notes.md", "remember the gate code")
    ConversationTurn.create!(
      account: @workspace.account, conversation: @conversation, position: 0,
      kind: "message", role: "user", status: "completed",
      speaker_actor: Actors::Resolve.member(account: @workspace.account, user: @human),
      control_owner_user: @human, visibility: "visible"
    ).tap do |turn|
      variant = ConversationTurnVariant.create!(
        account: @workspace.account, conversation_turn: turn, position: 0,
        status: "completed", source: "manual"
      )
      ContentBodies::Replace.call(owner: variant, role: "content",
        entries: [{ "text" => "an earlier thing I said" }], seal: true)
      turn.update!(active_variant: variant)
    end
    @conversation.reload.update!(timeline_position_head: 1)

    text = assemble.messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_operator text.index("remember the gate code"), :<,
      text.index("an earlier thing I said"),
      "memory changes on write, history changes every reply — memory first is " \
      "the order that keeps the front of the prefix warm"
  end

  test "both scopes reach the block; a workspace document is visible from a conversation" do
    write!("workspace/shared.md", "workspace fact")
    write!("conversation/private.md", "conversation fact")

    text = assemble.messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes text, "workspace fact"
    assert_includes text, "conversation fact"
    assert_includes text, "workspace/shared.md"
    assert_includes text, "conversation/private.md"
  end

  # THREE SCOPES, ONE BUDGET, NEWEST FIRST: no per-scope share and no ranking — the kernel ships no
  # ranking policy, and "newest first" is the one rule on file. The header names all three so a
  # model knows where a `user/` note came from.
  test "three scopes reach one block under one budget, newest first" do
    write!("workspace/shared.md", "workspace fact")
    travel 1.minute
    write!("conversation/private.md", "conversation fact")
    travel 1.minute
    write!("user/mine.md", "user fact")

    result = Conversations::ContextAssembly::MemoryBlock.call(
      conversation: @conversation.reload, principal: @human
    )
    assert_equal 3, result.included
    text = result.segments.sole.text
    assert_includes text, "## user/mine.md\nuser fact"
    assert_operator text.index("user/mine.md"), :<, text.index("conversation/private.md")
    assert_operator text.index("conversation/private.md"), :<, text.index("workspace/shared.md")
    assert_includes Conversations::ContextAssembly::MemoryBlock::HEADER, "conversation"
    assert_includes Conversations::ContextAssembly::MemoryBlock::HEADER, "workspace"
    assert_includes Conversations::ContextAssembly::MemoryBlock::HEADER, "person"

    write!("workspace/huge.md", "x" * 40.kilobytes)
    bounded = Conversations::ContextAssembly::MemoryBlock.call(
      conversation: @conversation.reload, principal: @human, budget: 8.kilobytes
    )
    assert_equal 0, bounded.included, "one budget across the three, a prefix of the newest"
    assert_equal 4, bounded.omitted
  end

  # THE TURN'S PRINCIPAL DECIDES WHOSE `user/` IS RENDERED (the Human-B case): a note under one
  # person's scope is absent from a turn another person posts into the same conversation.
  test "user/ is rendered for the TURN's principal, not the conversation's creator" do
    write!("user/owners.md", "the owner's private note", by: users(:owner))
    write!("user/members.md", "the member's private note", by: @human)

    as_owner = assemble(principal: users(:owner)).messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes as_owner, "the owner's private note"
    refute_includes as_owner, "the member's private note"

    as_member = assemble(principal: @human).messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes as_member, "the member's private note"
    refute_includes as_member, "the owner's private note"

    as_agent = assemble(principal: @agent).messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes as_agent, "the owner's private note",
      "an agent's turn renders its steward's notes — the person's memory for their agents"
  end

  # A SPAWNED CHILD anchors `user/` on its ANSWERER: the spawner briefs it, a person or a parent
  # `send` may post into it, but the notes rendered are the child agent's steward's every turn.
  test "a spawned child renders its answerer's steward's user/, whoever posts the turn" do
    write!("user/owners.md", "the owner's private note", by: users(:owner))
    write!("user/members.md", "the member's private note", by: @human)
    node = seed(model("r1", "prompt" => "go"), creating_user: @human).agent_loop_nodes.first
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id, spawn_node: node)

    as_member = assemble(principal: @human).messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes as_member, "the owner's private note", "the answerer's steward's notes"
    refute_includes as_member, "the member's private note", "never the poster's"
  end

  test "a principal with no controlling Human renders no user rung, and no error" do
    write!("user/mine.md", "user fact")
    write!("workspace/shared.md", "workspace fact")

    text = assemble(principal: users(:system)).messages.flat_map { |m| m.parts.map(&:text) }.join("\n")
    assert_includes text, "workspace fact"
    refute_includes text, "user fact"
  end

  # 64 documents at 64 KiB is on the order of a million tokens, on EVERY
  # reply. The budget is what makes this block usable rather than smaller.
  test "the budget bounds the block, and what does not fit is NAMED" do
    write!("workspace/huge.md", "x" * 40.kilobytes)
    travel 1.minute
    write!("workspace/small.md", "tiny")

    result = Conversations::ContextAssembly::MemoryBlock.call(
      conversation: @conversation.reload, principal: @human, budget: 8.kilobytes
    )
    assert_equal 1, result.included
    assert_equal 1, result.omitted

    text = result.segments.sole.text
    assert_includes text, "tiny"
    refute_includes text, "x" * 100
    assert_includes text, "workspace/huge.md",
      "a model that cannot see a document must at least know it exists"
  end

  # THE BLOCK IS ALWAYS A PREFIX OF THE NEWEST DOCUMENTS. Stopping at the
  # first miss rather than skipping past it is what makes membership
  # predictable — and it means an oversized NEWEST document takes the
  # block with it rather than defeating the budget the block exists for.
  test "an oversized newest document is omitted like any other, block and all" do
    write!("workspace/small.md", "tiny")
    travel 1.minute
    write!("workspace/huge.md", "x" * 40.kilobytes)

    result = Conversations::ContextAssembly::MemoryBlock.call(
      conversation: @conversation.reload, principal: @human, budget: 8.kilobytes
    )
    assert_equal 0, result.included
    assert_equal 2, result.omitted
    assert_predicate result, :empty?,
      "including it anyway would defeat the budget in the one case it is for"
  end

  test "newest first, because a document rewritten today is the one this reply turns on" do
    write!("workspace/old.md", "old")
    travel 1.hour
    write!("workspace/new.md", "new")

    text = Conversations::ContextAssembly::MemoryBlock.call(
      conversation: @conversation.reload, principal: @human
    ).segments.sole.text
    assert_operator text.index("workspace/new.md"), :<, text.index("workspace/old.md")
  end

  # A memory write changes the assembled context, so it owes the same
  # fence every other assembly-affecting write owes — clients CAS on it.
  test "a memory write bumps context_revision, and a refusal does not" do
    before = @conversation.context_revision
    write!("workspace/notes.md", "x")
    assert_equal before + 1, @conversation.reload.context_revision

    refused = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: "nope.md", by: @human),
      conversation: @conversation, path: "nope.md", content: "x", by: @human
    )
    assert_equal :memory_path_invalid, refused.outcome
    assert_equal before + 1, @conversation.reload.context_revision,
      "a refusal changed nothing, so it must not tell clients their view is stale"
  end

  test "an archived conversation takes no memory writes" do
    write!("workspace/notes.md", "x")
    Conversations::Archive.call(conversation: @conversation)

    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation.reload, path: "workspace/notes.md", by: @human),
      conversation: @conversation.reload, path: "workspace/notes.md", content: "y", by: @human
    )
    assert_equal :conversation_archived, result.outcome
  end

  # Memory is funded like the prompt: it never yields, only history does.
  test "memory is funded before history, so it cannot push an assembly past the window" do
    write!("workspace/big.md", "m" * 8.kilobytes)
    selection = DevModelLane.selection(workload: "text_generation")

    assembled = Conversations::ContextAssembly.assemble(
      conversation: @conversation.reload, prompt: "go", principal: @human,
      profile: selection.execution_profile, limits: selection.capabilities.limits
    )
    assert_equal 1, assembled.memory.included
    assert_operator assembled.history.selected_count, :>=, 0,
      "memory is funded first; history is what yields"
  end

  # THE BLOCK IS FROZEN FOR THE TURN: round one's assembly leads with it and every continuation
  # replays round one's sealed request, so a note the loop writes mid-turn is read by the NEXT turn,
  # never this one's.
  test "a note the loop writes lands in the next turn's block, not this one's" do
    memory_tools = Nexus::ToolRegistry::LIVE.filter_map do |canonical, tool|
      next unless canonical.start_with?("nexus.memory.")

      { "type" => "function", "function" => tool.wire_schema }
    end
    declare_tools!(@agent, tools: memory_tools)
    _turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent, text: "note the plan")
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("writing", tool_calls: [
      { id: "call_w", name: "memory_write",
        arguments: JSON.generate("path" => "conversation/plan.md", "content" => "the gate code is 4242") },
    ]))
    AgentLoops::Memory::Run.call(node: agent_loop.agent_loop_nodes.find_by!(tool_name: "memory_write"))
    schedule_loop!(agent_loop)

    continuation = agent_loop.agent_loop_nodes.where(continuation_source: "round").order(:id).last
    replayed = round_request_entries(continuation).map { |payload| payload.dig("parts", 0, "text").to_s }
    refute replayed.any? { |text| text.include?("4242") }, "this turn's rounds never see the note"
    refute replayed.any? { |text| text.include?(Conversations::ContextAssembly::MemoryBlock::HEADER) }

    run_loop_round!(agent_loop, sse_success("noted"))
    assert_equal "completed", agent_loop.reload.status
    Conversations::Turns::Converge.call

    text = Nexus::ModelRequestInput.text_segments(assemble(prompt: "what was it").messages).join("\n")
    assert_includes text, "the gate code is 4242"
    assert_includes text, "conversation/plan.md"
    assert_operator text.index(Conversations::ContextAssembly::MemoryBlock::HEADER), :<,
      text.index("Mock: writing"), "and the next turn reads it where memory always leads"
  end

  # SILENT UNDER AN OVERRIDE: the provider's memory is not the kernel's to render, and rendering the
  # kernel's beside it would be two memories under one name. The rows stay, so clearing restores the
  # block.
  test "under an override the block renders NOTHING, and the rows are still there" do
    write!("workspace/shared.md", "workspace fact")
    write!("conversation/private.md", "conversation fact")
    write!("user/mine.md", "user fact")
    provider = connect_provider(identifier: "mem", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    set = ->(overrides) {
      Workspaces::SetToolProviderOverrides.call(
        workspace: @workspace, by: users(:owner), lock_version: @workspace.reload.lock_version,
        overrides: overrides
      )
    }
    assert_equal :updated, set.call({ "nexus.memory" => provider.public_id }).outcome

    assembled = assemble
    assert_predicate assembled.memory, :empty?
    assert_equal 0, assembled.memory.included
    assert_equal 0, assembled.memory.omitted, "not 'too large', not shown at all"
    assert_equal ["now what"], assembled.messages.map { |m| m.parts.first.text }
    assert_equal 3, MemoryDocument.count, "the kernel's rows wait untouched"

    assert_equal :updated, set.call({}).outcome
    restored = assemble.memory
    assert_equal 3, restored.included
    assert_includes restored.segments.sole.text, "user fact"
  end

  # THE BLOCK NEVER RENDERS A SKILL: a `skills/` row is loaded on demand through the `skill` tool;
  # injected whole into every reply's prefix it would be the opposite of one.
  test "a skills/ row on any rung is excluded from the block" do
    write!("workspace/notes.md", "remember the gate code")
    [["workspace/skills/commit-style", @human], ["user/skills/review", @human]].each do |path, by|
      result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: by), conversation: @conversation, path: path, content: "# never shown",
        by: by, description: "a skill")
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    block = assemble.memory
    assert_equal 1, block.included
    assert_equal 0, block.omitted
    text = block.segments.first.text
    assert_includes text, "remember the gate code"
    assert_not_includes text, "never shown"
    assert_not_includes text, "skills/"
  end
end
