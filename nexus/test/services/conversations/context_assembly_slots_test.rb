require "test_helper"

# THE DEFAULT TEMPLATE'S SLOTS: the three slot blocks lead the sealed list as its first system-role
# items — merged into ONE by the wire rule when every slot is `system`, each document its own part —
# ahead of memory, history, the inline lead, the tail and the input; funded in the budget; macros
# substituted from named sources; an inline entry naming a slot replaces it for the turn and the
# row stands.
class Conversations::ContextAssemblySlotsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def register!(slot, content, on:, role: nil)
    anchor = on.is_a?(Workspace) ? { workspace: on } : { user: on }
    result = PromptDocuments::Write.call(anchor: anchor, slot: slot, content: content, role: role)
    assert_predicate result, :written?, result.outcome.inspect
    result.document
  end

  def write_memory!(path, content)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: @human),
      conversation: @conversation, path: path, content: content, by: @human
    )
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  def settle_turn!(text, position: 0, role: "user")
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

  def assemble(prompt: "now what", principal: @human, declaring_profile: @agent, **overrides)
    Conversations::ContextAssembly.assemble(**{
      conversation: @conversation.reload, prompt: prompt, principal: principal,
      declaring_profile: declaring_profile,
    }.merge(overrides))
  end

  def roles(assembled) = assembled.messages.map(&:role)
  def text_of(message) = message.parts.last.text
  # A merged item keeps each segment's text as its own part: the wire merges, nothing folds.
  def texts_of(message) = message.parts.map(&:text)

  test "THE ORDER: the slots, then memory, history, the lead and the prompt; a merge keeps each part" do
    register!("system_prompt", "I am the agent.", on: @agent)
    register!("character", "This is the room.", on: @workspace)
    register!("persona", "This is the person.", on: @human, role: "user")
    write_memory!("workspace/notes.md", "gate code 4471")
    settle_turn!("an earlier thing I said")
    settle_turn!("an earlier answer", position: 1, role: "assistant")

    assembled = assemble(inline: [{ "role" => "developer", "position" => "lead", "text" => "env block" }])

    assert_equal %w[system user assistant developer user], roles(assembled)
    assert_equal ["I am the agent.", "This is the room."], assembled.messages[0].parts.map(&:text),
      "the two system slots are one item, each document its own part, slot order kept"
    persona, memory, history = assembled.messages[1].parts.map(&:text)
    assert_equal 3, assembled.messages[1].parts.length,
      "the user-role persona, memory and history's user turn merge into one item, each its own part: no fold"
    assert_equal "This is the person.", persona
    assert memory.start_with?(Conversations::ContextAssembly::MemoryBlock::HEADER), "memory follows the slots"
    assert_equal "an earlier thing I said", history
    assert_equal "an earlier answer", text_of(assembled.messages[2])
    assert_equal "env block", text_of(assembled.messages[3]), "the lead rides BEHIND history, ahead of the prompt"
    assert_equal "now what", text_of(assembled.messages[4])
    assert_equal({ "system_prompt" => 1, "character" => 1, "persona" => 1 }, assembled.slots.versions)
  end

  test "a user-role persona stands as its own item after the two system slots" do
    register!("system_prompt", "I am the agent.", on: @agent)
    register!("character", "This is the room.", on: @workspace)
    register!("persona", "This is the person.", on: @human, role: "user")

    assembled = assemble
    assert_equal %w[system user], roles(assembled)
    assert_equal ["I am the agent.", "This is the room."], texts_of(assembled.messages[0])
    assert_equal ["This is the person.", "now what"], texts_of(assembled.messages[1]),
      "a user-role slot merges with the next user item, as the wire rule says"
  end

  test "an absent slot renders nothing — no empty item" do
    register!("character", "This is the room.", on: @workspace)

    assembled = assemble
    assert_equal %w[system user], roles(assembled)
    assert_equal "This is the room.", text_of(assembled.messages[0])
    assert_equal({ "character" => 1 }, assembled.slots.versions)

    PromptDocument.delete_all
    assembled = assemble
    assert_equal %w[user], roles(assembled), "no slots at all: the list opens with the prompt"
    assert_equal({}, assembled.slots.versions)
  end

  test "THE OVERRIDE: an inline slot entry replaces the registered slot for this assembly only" do
    character = register!("character", "This is the room.", on: @workspace)
    register!("persona", "This is the person.", on: @human)

    assembled = assemble(inline: [{ "slot" => "character", "text" => "the override" }])
    assert_equal ["the override", "This is the person."], texts_of(assembled.messages[0])
    assert_equal 1, character.reload.version, "the row is untouched"
    assert_equal "This is the room.", character.content

    assembled = assemble(inline: [{ "slot" => "character", "text" => "the override", "role" => "user" }])
    assert_equal %w[user system user], roles(assembled),
      "the override's own role breaks the run; slot order still puts the character first"
    assert_equal "the override", text_of(assembled.messages[0])
    assert_equal "This is the person.", text_of(assembled.messages[1])
    assert_equal "now what", text_of(assembled.messages[2])
  end

  test "an override on a slot nobody registered still lands in slot order" do
    register!("persona", "This is the person.", on: @human)

    assembled = assemble(inline: [{ "slot" => "system_prompt", "text" => "Be terse." }])
    assert_equal ["Be terse.", "This is the person."], texts_of(assembled.messages[0])
    assert_equal({ "persona" => 1 }, assembled.slots.versions, "an override has no version")

    assembled = assemble(inline: [{ "slot" => "persona", "text" => "P" }, { "slot" => "system_prompt", "text" => "S" }])
    assert_equal %w[S P], texts_of(assembled.messages[0]), "slot order, not entry order"
  end

  test "THE MACROS: the four names substitute from their named sources" do
    register!("character", "Room {{workspace}} on {{date}}.", on: @workspace)
    register!("persona", "Person {{ user }} with {{agent}}.", on: @human)

    travel_to Time.utc(2026, 9, 8, 12) do
      assembled = assemble
      assert_equal ["Room Shared on 2026-09-08.", "Person Member with Fixture Agent."],
        texts_of(assembled.messages[0])
    end

    assembled = assemble(declaring_profile: nil)
    assert_includes text_of(assembled.messages[0]), "Person Member with .",
      "no declaring profile: {{agent}} renders empty"
  end

  test "THE FUNDING: the slots are priced ahead of history like memory" do
    profile = DevModelLane.profile_for("dev/mock-text")
    limits = LimitsOf.bounds(hard: 400)
    3.times { |n| settle_turn!("turn #{n} " * 20, position: n) }

    before = assemble(profile: profile, limits: limits).history.selected_count
    register!("character", "room " * 200, on: @workspace)
    after = assemble(profile: profile, limits: limits).history.selected_count

    assert_operator after, :<, before, "a 200-word character shrinks the history budget"
  end

  test "THE DECLARING PROFILE: a Human's turn with none renders no system_prompt; no Human, no persona" do
    register!("system_prompt", "I am the agent.", on: @agent)
    register!("persona", "This is the person.", on: @human)

    assembled = assemble(declaring_profile: nil)
    assert_equal "This is the person.", text_of(assembled.messages[0])

    assembled = assemble(principal: users(:system))
    assert_equal "I am the agent.", text_of(assembled.messages[0]),
      "the system user answers to no Human, so no persona"
  end
end
