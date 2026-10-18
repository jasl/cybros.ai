require "test_helper"

# THE `agent/` RUNG: the answering agent's own documents. They follow the
# answerer across workspaces as `user/` follows a person, belong to no
# sibling under the same steward, anchor on the users column beside `user/`
# rows without a column of their own, are absent where no agent answers,
# and are never copied by a fork.
class MemoryDocuments::AgentRungTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  CONFIGURATION = {
    tool_definitions: [], approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "default",
    prompt_template: nil, compaction_policy: { mode: "kernel" }, default_model: nil, fallback_models: [],
  }.freeze

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @reviewer = Users::DeclareNamedAgent.call(caller: @agent, name: "reviewer", scope: "steward",
      description: "Reviews.", configuration: CONFIGURATION).user
    @here = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, answering_user: @reviewer)
    @there = Conversation.create!(workspace: workspaces(:dedicated), creating_user: @owner, answering_user: @reviewer)
  end

  def write!(conversation, path, content, by: @owner)
    result = Conversations::Memory::Apply.write(conversation: conversation, path: path, content: content, by: by,
      expected: memory_expectation)
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value
  end

  def context(conversation, principal: @owner, configuration: conversation.memory_context)
    MemoryDocuments::Context.new(workspace: conversation.workspace, conversation: conversation, principal: principal,
      configuration: configuration, agent: conversation.answering_agent)
  end

  def paths(conversation, principal: @owner) = context(conversation, principal: principal).listing.map(&:path)

  test "a named row's notes follow it across workspaces and belong to no sibling" do
    document = write!(@here, "agent/notes.md", "short answers")

    assert_equal @reviewer.id, document.user_id, "anchored on the named row, in the users column"
    assert_nil document.workspace_id
    assert_nil document.conversation_id
    assert_includes paths(@there), "agent/notes.md", "the same row answers there, so it reads its own notes"
    assert_equal "short answers", context(@there).resolve("agent/notes.md").documents.sole.content

    sibling = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, answering_user: @agent)
    assert_not_includes paths(sibling), "agent/notes.md", "the paired program's own rung is its own row's"
    assert_not_includes paths(sibling), "user/notes.md", "and the steward's user/ never carried it"
  end

  test "an explicit user binding is the Human principal's while agent memory remains the answerer's" do
    @here.update!(memory_context: { "bindings" => %w[conversation user agent].map do |scope|
      { "name" => scope, "scope" => scope, "access" => "read_write" }
    end })
    write!(@here, "agent/mine.md", "the reviewer's")
    write!(@here, "user/plan.md", "the owner's", by: @owner)

    listed = paths(@here, principal: @owner)
    assert_includes listed, "agent/mine.md"
    assert_includes listed, "user/plan.md"

    member = users(:member)
    as_member = paths(@here, principal: member)
    assert_includes as_member, "agent/mine.md", "the answerer's rung does not depend on who posts"
    assert_not_includes as_member, "user/plan.md", "the explicit user/ rung belongs to the acting Human"

    as_agent = paths(@here, principal: @agent)
    assert_includes as_agent, "agent/mine.md"
    assert_not_includes as_agent, "user/plan.md", "an Agent never inherits its steward's user memory"
  end

  test "speaker memory follows the same answering Agent and Speaker pair across workspaces" do
    speaker = Speakers::Resolve.member(account: @account, user: @owner)
    configuration = MemoryContext.capture(configuration: nil, speaker: speaker)
    @here.update!(memory_context: configuration)
    @there.update!(memory_context: configuration)
    document = write!(@here, "speaker/preferences.md", "concise reviews")

    assert_equal @reviewer.id, document.user_id
    assert_equal speaker.id, document.speaker_id
    assert_nil document.workspace_id
    assert_nil document.conversation_id
    assert_includes paths(@there), "speaker/preferences.md"
    assert_equal "concise reviews", context(@there).resolve("speaker/preferences.md").documents.sole.content

    other_speaker = Speakers::Resolve.member(account: @account, user: users(:member))
    other_context = context(@there, configuration: MemoryContext.capture(configuration: nil, speaker: other_speaker))
    assert_not_includes other_context.listing.map(&:path), "speaker/preferences.md"
    sibling = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, answering_user: @agent,
      memory_context: configuration)
    assert_not_includes paths(sibling), "speaker/preferences.md", "the same Speaker does not share notes between Agents"
  end

  test "a Human-answered conversation has no agent rung, and an explicit binding naming it is unavailable" do
    plain = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, answering_user: @owner)

    assert_equal :memory_scope_unavailable, context(plain).resolve("agent/notes.md").refusal
    outcome = Conversations::SetMemoryContext.call(conversation: plain, acting_user: @owner,
      memory_context: { "bindings" => [
        { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
        { "name" => "agent", "scope" => "agent", "access" => "read_write" },
      ] })
    assert_equal :memory_scope_unavailable, outcome.outcome
  end

  test "the default bindings carry the rung; an explicit configuration may leave it out or narrow it to read" do
    write!(@here, "agent/notes.md", "short answers")
    assert_equal %w[agent conversation speaker workspace], MemoryContext::DEFAULT.bindings.map(&:name).sort
    assert_equal %w[agent conversation workspace], context(@here).bindings.map(&:name).sort,
      "a member read cannot infer an input Speaker"
    assert_equal :memory_scope_unavailable, context(@here).resolve("user/notes.md").refusal
    assert_equal :memory_scope_unavailable, context(@here).resolve("speaker/notes.md").refusal

    narrowed = Conversations::SetMemoryContext.call(conversation: @here, acting_user: @owner,
      memory_context: { "bindings" => [
        { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
        { "name" => "agent", "scope" => "agent", "access" => "read" },
      ] })
    assert_predicate narrowed, :accepted?
    reread = context(@here.reload)
    assert_equal %w[agent conversation], reread.bindings.map(&:name).sort
    assert_equal :memory_read_only, reread.resolve("agent/notes.md", authoring: true).refusal
    assert_equal "agent/notes.md", reread.listing.sole.path
  end

  test "a fork copies the conversation rung and nothing of the agent's" do
    write!(@here, "agent/notes.md", "short answers")
    write!(@here, "conversation/plan.md", "this thread's plan")
    turn = Turn.create!(
      account: @account, conversation: @here, position: 0, kind: "message", role: "user", status: "completed",
      speaker: Speakers::Resolve.member(account: @account, user: @owner), control_owner_user: @owner,
      visibility: "visible"
    )
    variant = Variant.create!(account: @account, turn: turn, position: 0,
      status: "completed", source: "manual")
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => "hi" }], seal: true)
    turn.update!(active_variant: variant)
    @here.reload.update!(timeline_position_head: 1)

    fork = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @here.reload, turn_public_id: turn.public_id, variant_public_id: variant.public_id,
      acting_user: @owner, title: nil
    )).value

    assert_equal 1, MemoryDocument.for_conversation(fork.id).count, "the conversation rung is copied by pointer"
    assert_equal 1, MemoryDocument.for_user(@reviewer.id).count, "the agent rung is one row, the answerer's"
    assert_includes paths(fork), "agent/notes.md", "and the fork answers as its source does, so it reads it live"
  end

  test "the memory block renders the answerer's rung and a sibling's block does not" do
    write!(@here, "agent/notes.md", "short answers")

    block = Conversations::ContextAssembly::MemoryBlock.call(conversation: @here.reload, principal: @owner,
      agent: @here.answering_agent)
    assert_includes block.segments.sole.text, "agent/notes.md"

    sibling = Conversation.create!(workspace: workspaces(:shared), creating_user: @owner, answering_user: @agent)
    other = Conversations::ContextAssembly::MemoryBlock.call(conversation: sibling, principal: @owner,
      agent: sibling.answering_agent)
    assert_predicate other, :empty?
  end
end
