require "test_helper"

# THE PINNED RENDERING of a non-default template: the block order read from the profile's
# `prompt_template`, the same merge rule as `default` — so persona, memory and history's user turn
# merge into ONE user item, each its own part — the variable substituted from the turn's value over
# the template's default; the negative: the same profile under `default` renders the built-in order
# and none of the template's text.
class Conversations::ContextAssemblyLayoutTest < ActiveSupport::TestCase
  TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "inline", "role" => "user", "text" => "Scene: {{scene}}, with {{agent}}." },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" },
      { "type" => "history" },
      { "type" => "input" },
    ],
    "variables" => { "scene" => "an ordinary day" },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    register!("system_prompt", "I am the agent.", on: @agent, role: "developer")
    register!("character", "This is the room.", on: @workspace)
    register!("persona", "This is the person.", on: @human, role: "user")
    write_memory!("workspace/notes.md", "gate code 4471")
    settle_turn!("hi there", role: "user", position: 0)
    settle_turn!("hello back", role: "assistant", position: 1)
  end

  def declare!(mechanism, template: TEMPLATE)
    outcome = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: mechanism,
      prompt_template: template, compaction_policy: nil
    )
    assert_equal :declared, outcome.outcome
  end

  def register!(slot, content, on:, role: nil)
    anchor = on.is_a?(Workspace) ? { workspace: on } : { user: on }
    result = PromptDocuments::Write.call(anchor: anchor, slot: slot, content: content, role: role)
    assert_predicate result, :written?, result.outcome.inspect
    result.document
  end

  def write_memory!(path, content)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: @human), conversation: @conversation, path: path, content: content, by: @human)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  def settle_turn!(text, role:, position:)
    turn = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: position,
      kind: "message", role: role, status: "completed",
      speaker_actor: Actors::Resolve.member(account: @account, user: @human),
      control_owner_user: @human, visibility: "visible"
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn, position: 0, status: "completed", source: "manual"
    )
    ContentBodies::Replace.call(owner: variant, role: "content", entries: [{ "text" => text }], seal: true)
    turn.update!(active_variant: variant)
    @conversation.reload.update!(timeline_position_head: position + 1)
  end

  def assemble(**overrides)
    Conversations::ContextAssembly.assemble(**{
      conversation: @conversation.reload, prompt: "now what", principal: @human,
      declaring_profile: @agent.reload, answerer: @agent,
      template: PromptTemplate.for_profile(@agent.reload),
    }.merge(overrides))
  end

  def roles(assembled) = assembled.messages.map(&:role)
  def text_of(message) = message.parts.map(&:text).join
  # A merged item keeps each segment's text as its own part: the wire merges, nothing folds.
  def texts_of(message) = message.parts.map(&:text)
  def memory_text = Conversations::ContextAssembly.assemble(
    conversation: @conversation.reload, prompt: "x", principal: @human, declaring_profile: nil,
    template: PromptTemplate.parse("blocks" => [{ "type" => "memory" }, { "type" => "history" }, { "type" => "input" }])
  ).messages[0].parts.first.text

  test "THE TEMPLATE ORDER, merged by the wire rule, the variable from the turn over the default" do
    declare!("assembly")

    assembled = assemble(variables: { "scene" => "a rainy night" })

    assert_equal %w[developer user assistant user], roles(assembled)
    assert_equal "I am the agent.", text_of(assembled.messages[0])
    assert_equal ["Scene: a rainy night, with Fixture Agent.", "This is the person.", memory_text, "hi there"],
      texts_of(assembled.messages[1]),
      "the inline, the user-role persona, memory and history's user turn are adjacent user segments: " \
        "ONE item, each its own part"
    assert_equal "hello back", text_of(assembled.messages[2])
    assert_equal "now what", text_of(assembled.messages[3])
    assert_equal({ "system_prompt" => 1, "persona" => 1 }, assembled.slots.versions,
      "the character slot is not placed by this template, so it is neither rendered nor read")
    assert_equal %w[slot:system_prompt inline:1 slot:persona memory history input],
      assembled.blocks.map(&:key), "the evidence follows the template's order"
    assert_equal %w[selected] * 6, assembled.blocks.map(&:state)
    assert assembled.blocks.all? { |block| block.allocated_tokens.nil? }, "no window, no allocator"

    defaulted = assemble
    assert_equal ["Scene: an ordinary day, with Fixture Agent.", "This is the person.", memory_text, "hi there"],
      texts_of(defaulted.messages[1]), "the template's default stands when the turn names no value"
  end

  test "THE NEGATIVE: the same profile under default compiles the built-in order and none of the template" do
    declare!("default")

    assembled = assemble

    assert_equal %w[developer system user assistant user], roles(assembled)
    assert_equal "I am the agent.", text_of(assembled.messages[0])
    assert_equal "This is the room.", text_of(assembled.messages[1]), "the character slot rides under default"
    assert_equal ["This is the person.", memory_text, "hi there"], texts_of(assembled.messages[2])
    assert_no_match(/Scene:/, assembled.messages.map { |message| text_of(message) }.join)
    assert_equal %w[slot:system_prompt slot:character slot:persona memory skills history lead tail input],
      assembled.blocks.map(&:key)
    assert_equal %w[selected selected selected selected empty selected empty empty selected],
      assembled.blocks.map(&:state), "an absent lead or tail is an empty block, never an item"
  end

  test "a template without memory or the character slot renders neither; input last stays last" do
    declare!("assembly", template: { "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "history", "max_entries" => 1 },
      { "type" => "inline", "role" => "developer", "text" => "Answer in one line." },
      { "type" => "input" },
    ] })

    assembled = assemble

    assert_equal %w[developer assistant developer user], roles(assembled)
    assert_equal "I am the agent.", text_of(assembled.messages[0])
    assert_equal "hello back", text_of(assembled.messages[1]), "max_entries from the template: the newest turn only"
    assert_equal "Answer in one line.", text_of(assembled.messages[2])
    assert_equal "now what", text_of(assembled.messages[3])
    assert_predicate assembled.memory, :empty?
    assert_equal({ "system_prompt" => 1 }, assembled.slots.versions)
    assert_equal 1, assembled.history.selected_count
    assert_equal 1, assembled.history.skipped_count
    assert_equal "entry_limit", assembled.history.skipped_reason
  end

  test "the per-turn slot override and the lead land where the template puts them" do
    declare!("assembly", template: { "blocks" => [
      { "type" => "slot", "slot" => "persona" },
      { "type" => "lead" },
      { "type" => "history" },
      { "type" => "input" },
    ] })

    assembled = assemble(inline: [
      { "slot" => "persona", "text" => "P for this turn", "role" => "system" },
      { "role" => "developer", "text" => "env block" },
    ])

    assert_equal %w[system developer user assistant user], roles(assembled)
    assert_equal "P for this turn", text_of(assembled.messages[0])
    assert_equal "env block", text_of(assembled.messages[1])
    assert_equal({}, assembled.slots.versions, "an override has no version")
  end
end
