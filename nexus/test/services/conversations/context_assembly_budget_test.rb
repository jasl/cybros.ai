require "test_helper"

# THE ALLOCATOR WIRED: every slot, inline, memory, lead, tail and input block is a REQUIRED floor,
# history the one optional child — so history trims first, down to nothing, and a floor the window
# cannot fund is EVIDENCE (`floor_unmet`) on bytes that still send whole; only the window gate
# refuses, on its own terms. No window → no allocator: only stated caps constrain history.
class Conversations::ContextAssemblyBudgetTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @profile = DevModelLane.profile_for("dev/mock-text")
  end

  def register!(slot, content, on:)
    anchor = on.is_a?(Workspace) ? { workspace: on } : { user: on }
    result = PromptDocuments::Write.call(anchor: anchor, slot: slot, content: content)
    assert_predicate result, :written?, result.outcome.inspect
  end

  def register_three_full_slots!
    register!("system_prompt", "s" * 65_000, on: @agent)
    register!("character", "c" * 65_000, on: @workspace)
    register!("persona", "p" * 65_000, on: @human)
  end

  def write_memory!(path, content)
    result = Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @conversation, path: path, by: @human), conversation: @conversation, path: path, content: content, by: @human)
    assert_predicate result, :accepted?, result.outcome.inspect
  end

  def settle_turn!(text, position:)
    turn = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: position,
      kind: "message", role: "user", status: "completed",
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

  def template(history: { "type" => "history" })
    PromptTemplate.parse("blocks" => [
      { "type" => "slot", "slot" => "system_prompt" }, { "type" => "slot", "slot" => "character" },
      { "type" => "slot", "slot" => "persona" }, { "type" => "memory" }, history, { "type" => "input" },
    ])
  end

  def assemble(limits:, profile: @profile, **overrides)
    Conversations::ContextAssembly.assemble(**{
      conversation: @conversation.reload, prompt: "now what", principal: @human,
      declaring_profile: @agent, answerer: @agent, profile: profile, limits: limits,
    }.merge(overrides))
  end

  def block(assembled, key) = assembled.blocks.find { |block| block.key == key }

  test "HISTORY BEFORE THE SLOTS: three full slots on a small window trim history to nothing and drop no slot" do
    register_three_full_slots!
    3.times { |n| settle_turn!("turn #{n}", position: n) }

    assembled = assemble(limits: LimitsOf.bounds(advisory: 1_000, hard: 100_000))

    assert_equal 0, assembled.history.selected_count
    assert_equal "budget_exceeded", assembled.history.skipped_reason
    assert_equal 3, assembled.history.skipped_count
    system_item = assembled.messages[0]
    assert_equal "system", system_item.role
    assert_equal [65_000] * 3, system_item.parts.map { |part| part.text.bytesize }, "every slot renders whole, each its own part"
    assert_equal "now what", assembled.messages[1].parts.sole.text, "the input never yields"

    slots = %w[slot:system_prompt slot:character slot:persona].map { |key| block(assembled, key) }
    assert_equal %w[floor_unmet floor_unmet floor_unmet], slots.map(&:state),
      "the window cannot fund the floors: evidence, never a byte change"
    assert_equal 0, block(assembled, "history").allocated_tokens
    assert_equal "empty", block(assembled, "history").state
    assert_equal "selected", block(assembled, "input").state
    assert_operator slots.sum(&:tokens), :>, 1_000
  end

  test "memory is funded before history: history trims to nothing while memory rides whole" do
    write_memory!("workspace/notes.md", "gate " * 400)
    3.times { |n| settle_turn!("turn #{n} " * 10, position: n) }
    memory_cost = Conversations::ContextAssembly::FillCost.segment(
      Conversations::ContextAssembly::MemoryBlock.call(conversation: @conversation, principal: @human).segments.sole, @profile
    )

    assembled = assemble(limits: LimitsOf.bounds(advisory: memory_cost + 10, hard: nil))

    assert_equal 1, assembled.memory.included
    assert_equal "selected", block(assembled, "memory").state
    assert_equal memory_cost, block(assembled, "memory").tokens
    assert_equal 0, assembled.history.selected_count
    assert_equal "budget_exceeded", assembled.history.skipped_reason
    assert_operator block(assembled, "history").allocated_tokens, :<, 10
  end

  test "with headroom, history takes exactly the window less the answer room minus the floors" do
    register!("character", "room " * 50, on: @workspace)
    3.times { |n| settle_turn!("turn #{n}", position: n) }

    assembled = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 8_192))

    floors = assembled.blocks.reject { |block| block.key == "history" }.sum(&:tokens)
    assert_equal 7_168 - floors, block(assembled, "history").allocated_tokens,
      "8,192 less its 12.5 % answer room"
    assert_equal 3, assembled.history.selected_count
    assert_nil assembled.history.skipped_reason
    assert assembled.blocks.none? { |block| block.state == "floor_unmet" }, "every floor funded"
  end

  test "THE WINDOWLESS PIN: no window, no allocator — history unbounded, allocated_tokens nil" do
    windowless = DevModelLane.profile_for("dev/mock-windowless")
    register_three_full_slots!
    3.times { |n| settle_turn!("turn #{n}", position: n) }

    assembled = assemble(profile: windowless, limits: LimitsOf.bounds(advisory: nil, hard: nil))

    assert_equal 3, assembled.history.selected_count
    assert_nil assembled.history.skipped_reason
    assert assembled.blocks.all? { |block| block.allocated_tokens.nil? }, "nothing is sized"
    assert_equal %w[selected] * 4, %w[slot:system_prompt slot:character slot:persona history].map { |key| block(assembled, key).state }
  end

  test "the template's min_tokens is a floor for history only when room remains after the required floors" do
    register!("character", "room " * 200, on: @workspace)
    3.times { |n| settle_turn!("turn #{n} " * 10, position: n) }
    floors = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 100_000))
      .blocks.reject { |block| block.key == "history" }.sum(&:tokens)
    floored = template(history: { "type" => "history", "budget" => { "min_tokens" => 50, "max_tokens" => 60 } })

    roomy = assemble(limits: LimitsOf.bounds(advisory: floors + 55, hard: nil), template: floored)
    assert_equal 55, block(roomy, "history").allocated_tokens, "floored at 50, filled to the cap or the room"

    cramped = assemble(limits: LimitsOf.bounds(advisory: floors + 10, hard: nil), template: floored)
    assert_equal 0, block(cramped, "history").allocated_tokens,
      "ten tokens cannot meet a fifty-token floor: the optional child is excluded, never the slots"
    assert_equal 0, cramped.history.selected_count
    assert_equal "selected", block(cramped, "slot:character").state, "the required floors stayed funded"
  end

  test "a windowless model respects stated history caps including zero without dropping memory" do
    windowless = DevModelLane.profile_for("dev/mock-windowless")
    limits = LimitsOf.bounds(advisory: nil, hard: nil)
    write_memory!("conversation/notes.md", "A durable group fact")
    3.times { |n| settle_turn!("History that must not enter a memory-only preview #{n}", position: n) }

    [[0, nil, 0], [7, nil, 7], [7, 3, 3], [7, 30, 7]].each do |cap, explicit, expected|
      capped = template(history: { "type" => "history", "budget" => { "max_tokens" => cap } })
      assembled = assemble(profile: windowless, limits: limits, template: capped, history_token_budget: explicit)

      assert_equal expected, block(assembled, "history").allocated_tokens
      assert_equal 1, assembled.memory.included
      assert_equal "selected", block(assembled, "memory").state
      next unless cap.zero?

      assert_equal 0, assembled.history.selected_count
      assert_equal 3, assembled.history.skipped_count
      assert_equal "budget_exceeded", assembled.history.skipped_reason
    end
  end

  test "the template's max_tokens caps history under the window; a per-turn budget is the tighter cap" do
    3.times { |n| settle_turn!("turn #{n}", position: n) }
    capped = template(history: { "type" => "history", "budget" => { "max_tokens" => 7 } })

    assembled = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 8_192), template: capped)
    assert_equal 7, block(assembled, "history").allocated_tokens

    tighter = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 8_192), template: capped,
      history_token_budget: 3)
    assert_equal 3, block(tighter, "history").allocated_tokens
    assert_operator tighter.history.selected_count, :<=, assembled.history.selected_count
  end

  # THE ANSWER ROOM: on a shared or hard window the turn's own answer needs room the history must
  # leave — `min(32k, 12.5 %)` of it — whether or not reasoning replays; a row that plans to an
  # advisory bound below its hard window already has that room and takes no margin.
  test "history leaves the answer room on a hard window, replaying or not, and none under an advisory bound" do
    3.times { |n| settle_turn!("turn #{n}", position: n) }
    target = ModelReasoning::ReplayLadder::Target.new(
      provider_id: "prov", model_id: "m", reasoning_effort: "high",
      capability: Nexus::ReasoningReplayCapability.default
    )
    reasoning = Conversations::ContextAssembly::Replay.new(mode: "all", target: target)

    advisory = assemble(limits: LimitsOf.bounds(advisory: 8_000, hard: nil))
    advisory_replayed = assemble(limits: LimitsOf.bounds(advisory: 8_000, hard: nil), reasoning: reasoning)
    assert_equal block(advisory, "history").allocated_tokens, block(advisory_replayed, "history").allocated_tokens,
      "replay takes no room of its own: traces are history"

    hard = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 8_000))
    hard_replayed = assemble(limits: LimitsOf.bounds(advisory: nil, hard: 8_000), reasoning: reasoning)
    assert_equal block(advisory, "history").allocated_tokens - 1_000, block(hard, "history").allocated_tokens,
      "an 8,000-token hard window keeps 12.5 % for the answer"
    assert_equal block(hard, "history").allocated_tokens, block(hard_replayed, "history").allocated_tokens
  end
end
