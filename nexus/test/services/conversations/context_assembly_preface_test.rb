require "test_helper"

# THE NEXT TURN IS THE EARLIER REQUEST WHOLE. What a turn's request laid between history and its
# words — its PREFACE: the caller's lead and tail, a template's post-history inline — is sealed with
# the turn and replayed where it was sent, and every round's thinking replays too — reasoning is
# history, cut only with its turn. A lead the window already carries is laid once. So a later turn, an edited answer and a regenerated
# one open with what the model last read. Every pin compares against the earlier loop's LAST
# request plus its answer, never its round one, which every later round extends by construction.
class Conversations::ContextAssemblyPrefaceTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  LEAD = "Relative paths resolve against /w.".freeze
  WINDOWED = DevModelLane::WINDOWED_TEXT_MODEL.split("/", 2).last
  WINDOWED_OTHER = DevModelLane::WINDOWED_OTHER_MODEL.split("/", 2).last
  # A round thinks this many tokens unless it says otherwise: the fit prices
  # a native blob by the provider's own count. The fit window holds two such
  # thoughts beside a few turns of history, never three.
  THOUGHT_TOKENS = 1_000
  FIT_WINDOW = 2_600

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def converge! = Conversations::Turns::Converge.call

  # Character for character — the unit a provider's prefix cache matches.
  def canonical(entries) = entries.map { |payload| Nexus::CanonicalJson.encode(payload) }

  # Each entry as role and text — a merged message's texts as a list, each part its own — or a
  # replayed item's kind.
  def shape(entries)
    entries.map do |payload|
      case payload["type"]
      when "tool_call_item" then ["call", payload.dig("payload", "call_id")]
      when "tool_result_item" then ["result", payload.dig("payload", "call_id")]
      when "reasoning_item" then ["reasoning"]
      else
        texts = payload.fetch("parts").map { |part| part["text"] }
        [payload["role"], texts.one? ? texts.sole : texts]
      end
    end
  end

  def lead_options(text = LEAD) = { "inline" => [{ "role" => "developer", "position" => "lead", "text" => text }] }

  # A reply head on a windowed lane — every round's thinking replays by default, so the pins compare
  # whole requests — posted as the agent's own voice with its per-turn options, its round one composed.
  def windowed_turn!(text, model_ref: WINDOWED, **over)
    post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: text,
      provider_id: "dev", model_ref: model_ref, **over)
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    turn = @conversation.conversation_turns.order(:position).last
    agent_run = turn.active_variant.agent_run
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  def thought(text, blob, tool_calls: [], tokens: THOUGHT_TOKENS)
    sse_success(text, reasoning: "thinking #{blob}", reasoning_encrypted: blob, tool_calls: tool_calls,
      usage: { "input_tokens" => 2, "output_tokens" => tokens + 3,
               "output_tokens_details" => { "reasoning_tokens" => tokens } })
  end

  def replayed_blobs(entries)
    entries.filter_map { |payload| payload.dig("payload", "encrypted_content") if payload["type"] == "reasoning_item" }
  end

  # Two thinking rounds — a call, then the answer — so the loop's LAST mainline request carries the
  # first round's thinking and its answer the second's. Answers that last request.
  def two_thinking_rounds!(agent_run)
    run_loop_round!(agent_run, sse_success("calling", reasoning: "plan one", reasoning_encrypted: "blob-one",
      tool_calls: [{ id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" }]))
    settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_a"),
      trusted: true, content: "contents of a", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("done", reasoning: "plan two", reasoning_encrypted: "blob-two"))
    converge!
    assert_equal "completed", agent_run.reload.status
    round_request_entries(loop_node(agent_run, "r2"))
  end

  def preface_payloads(variant)
    variant.content_bodies.find_by!(role: "preface").entry_payloads
  end

  def regenerate!(turn, **overrides)
    Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(**{
      conversation: @conversation.reload, turn_public_id: turn.public_id,
      acting_user: @human, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
  end

  # ── THE PREFACE: what a turn placed between history and its words, replayed where it was sent ──

  test "a person's next turn re-sends its lead BEHIND history: round one is the last request plus the answer" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      turn1, loop1 = windowed_turn!("read the notes", context_options: lead_options)
      last = two_thinking_rounds!(loop1)
      assert_equal [["developer", LEAD], ["user", "read the notes"]], shape(last).first(2)

      turn2, loop2 = windowed_turn!("and next", context_options: lead_options)
      second = round_request_entries(loop_node(loop2, "r1"))

      assert_equal canonical(last), canonical(second).first(last.length),
        "turn N+1's prefix is turn N's LAST request whole — its lead, its words, the first round's thinking"
      assert_equal [["reasoning"], ["assistant", "Mock: done"], ["user", "and next"]],
        shape(second).drop(last.length),
        "then the answer with its thinking, then this turn's words: the window already carries the identical lead"
      assert_equal %w[blob-one blob-two], replayed_blobs(second)
      lead = { "role" => "developer", "parts" => [{ "type" => "text", "text" => LEAD }], "block" => "lead" }
      assert_equal [lead], preface_payloads(turn1.reload.active_variant),
        "the turn sealed what it placed between history and its words"
      assert_equal [lead.merge("carried" => true)], preface_payloads(turn2.reload.active_variant),
        "and a turn the window carried the lead for records the lead it relied on, never laid"
    end
  end

  test "a shorter lead stays carried through regeneration until its carrier leaves the window" do
    catalog = DevModelLane.windowed_catalog(input_tokens: 8_192)
    ModelCatalog.stub(:current, -> { catalog }) do
      declare_tools!(@agent)
      environment = { "role" => "user", "position" => "lead", "text" => "Selected workspace: /w." }
      original_options = { "inline" => [environment, *lead_options.fetch("inline")] }
      turn1, loop1 = windowed_turn!("read the notes #{"padding " * 3_000}", context_options: original_options)
      run_loop_round!(loop1, sse_success("noted"))
      converge!
      assert_equal "completed", turn1.reload.status
      first = round_request_entries(loop_node(loop1, "r1"))

      turn2, loop2 = windowed_turn!("and next", context_options: { "inline" => [environment] })
      second = round_request_entries(loop_node(loop2, "r1"))
      assert_equal canonical(first), canonical(second).first(first.length)
      assert_equal [["assistant", "Mock: noted"], ["user", "and next"]], shape(second).drop(first.length),
        "the complete environment segment is carried without repeating the source's product guidance"
      lead = { "role" => "user", "parts" => [{ "type" => "text", "text" => environment.fetch("text") }], "block" => "lead" }
      assert_equal [lead.merge("carried" => true)], preface_payloads(turn2.reload.active_variant)
      run_loop_round!(loop2, sse_success("next, done"))
      converge!

      regenerated = regenerate!(turn2, provider_id: "dev", model_ref: WINDOWED_OTHER)
      assert_predicate regenerated, :accepted?, regenerated.outcome.to_s
      regenerated_loop = regenerated.value.agent_run
      schedule_loop!(regenerated_loop)
      entries = round_request_entries(loop_node(regenerated_loop, "r1"))
      assert_equal canonical(second), canonical(entries), "a model switch reassembles the same carried prefix"
      assert_equal [lead.merge("carried" => true)], preface_payloads(regenerated.value.reload)
      run_loop_round!(regenerated_loop, sse_success("next, regenerated"))
      converge!

      catalog = DevModelLane.windowed_catalog(input_tokens: 1_024, other_input_tokens: 8_192)
      cut = regenerate!(turn2, provider_id: "dev", model_ref: WINDOWED)
      assert_predicate cut, :accepted?, cut.outcome.to_s
      cut_loop = cut.value.agent_run
      schedule_loop!(cut_loop)
      entries = round_request_entries(loop_node(cut_loop, "r1"))
      assert_not_includes entries.to_json, "padding"
      assert_equal ["user", [environment.fetch("text"), "and next"]], shape(entries).last,
        "without the carrier, regeneration lays the shorter lead the turn relied on"
      assert_equal 1, canonical(entries).join.scan(environment.fetch("text")).length
      assert_equal [lead], preface_payloads(cut.value.reload)
    end
  end

  test "lead carrying compares complete ordered segments rather than shared text or membership" do
    declare_tools!(@agent)
    environment = { "role" => "user", "position" => "lead", "text" => "Selected workspace: /w." }
    guidance = lead_options.fetch("inline").sole
    _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: "read the notes",
      context_options: { "inline" => [environment, guidance] })
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("noted"))
    converge!

    [[guidance], [environment, guidance.merge("text" => "New guidance.")],
     [environment.merge("role" => "developer")], [environment.merge("text" => "Selected workspace:")]].each do |inline|
      assembled = Conversations::ContextAssembly.assemble(conversation: @conversation.reload, principal: @agent,
        declaring_profile: @agent, answerer: @agent, prompt: "and next", inline: inline)
      assert_equal inline.map { |entry| [entry.fetch("role"), entry.fetch("text")] },
        Conversations::ContextAssembly::Preface.pairs(assembled.preface)
      assert assembled.preface.none?(&:carried), "a suffix, changed segment, role or partial text is a new lead"
    end
  end

  # THE LEAD IS LAID WHEN THE WINDOW DOES NOT CARRY IT: the newest in-window own preface that
  # carries a lead is the one compared, so A, B, A lays A again (the model reads the lead it
  # should), and a carrier the window no longer holds leaves the next turn to lay it.
  test "a lead is laid again when it differs from the newest carrier or the carrier left the window" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      moved = "Relative paths resolve against /w2."
      [LEAD, moved].each_with_index do |lead, index|
        turn, agent_run = windowed_turn!("ask #{index}", context_options: lead_options(lead))
        run_loop_round!(agent_run, sse_success("answer #{index}"))
        converge!
        assert_equal "completed", turn.reload.status
      end

      turn3, loop3 = windowed_turn!("ask 2", context_options: lead_options)
      assert_equal [["developer", LEAD], ["user", "ask 2"]], shape(round_request_entries(loop_node(loop3, "r1"))).last(2),
        "A, B, A: the newest carrier says B, so A is laid"
      run_loop_round!(loop3, sse_success("answer 2"))
      converge!
      assert_equal "completed", turn3.reload.status

      _turn4, loop4 = windowed_turn!("ask 3", context_options: lead_options.merge("history" => { "max_entries" => 1 }))
      assert_equal [["developer", LEAD], ["user", "ask 3"]], shape(round_request_entries(loop_node(loop4, "r1"))).last(2),
        "a stated bound left the carrier out of the window: the turn lays its lead"
    end
  end

  # A turn that relied on the window to carry its lead records the lead it relied on, never laid. A
  # re-ask whose own window no longer holds that carrier — here a smaller-window model — lays it,
  # so the model never answers without it, and the sibling seals what its request laid.
  test "a regeneration whose window cut the lead's carrier lays the lead the turn relied on" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192, other_input_tokens: 1_024)) do
      declare_tools!(@agent)
      turn1, loop1 = windowed_turn!("read the notes #{"padding " * 3_000}", context_options: lead_options)
      run_loop_round!(loop1, sse_success("noted"))
      converge!
      assert_equal "completed", turn1.reload.status
      turn2, loop2 = windowed_turn!("and next", context_options: lead_options)
      assert_equal ["user", "and next"], shape(round_request_entries(loop_node(loop2, "r1"))).last
      assert_equal 1, canonical(round_request_entries(loop_node(loop2, "r1"))).join.scan(LEAD).length,
        "the window carried the lead"
      run_loop_round!(loop2, sse_success("next, done"))
      converge!
      assert_equal "completed", turn2.reload.status
      lead = { "role" => "developer", "parts" => [{ "type" => "text", "text" => LEAD }], "block" => "lead" }
      assert_equal [lead.merge("carried" => true)], preface_payloads(turn2.reload.active_variant),
        "the turn records the lead it relied on the window for"

      result = regenerate!(turn2, provider_id: "dev", model_ref: WINDOWED_OTHER)
      assert_predicate result, :accepted?, result.outcome.to_s
      sibling_loop = result.value.agent_run
      schedule_loop!(sibling_loop)
      entries = round_request_entries(loop_node(sibling_loop, "r1"))

      assert_not_includes entries.to_json, "padding", "the smaller window cut the carrier"
      assert_equal [["developer", LEAD], ["user", "and next"]], shape(entries).last(2)
      assert_equal 1, canonical(entries).join.scan(LEAD).length
      assert_equal [lead], preface_payloads(result.value.reload), "the sibling seals the lead its request laid"
    end
  end

  test "a changed lead is appended, never edited; a turn without one after it is a pure append" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      turn1, loop1 = windowed_turn!("read the notes", context_options: lead_options)
      last = two_thinking_rounds!(loop1)

      moved = "Relative paths resolve against /w2."
      turn2, loop2 = windowed_turn!("and next", context_options: lead_options(moved))
      second = round_request_entries(loop_node(loop2, "r1"))
      assert_equal canonical(last), canonical(second).first(last.length),
        "the environment moved: the earlier lead stands where it was sent"
      assert_equal [["developer", moved], ["user", "and next"]], shape(second).last(2),
        "and the new one rides the newest turn"
      assert_equal LEAD, preface_payloads(turn1.reload.active_variant).sole.dig("parts", 0, "text")
      run_loop_round!(loop2, sse_success("next done", reasoning: "plan three", reasoning_encrypted: "blob-three"))
      converge!
      assert_equal "completed", turn2.reload.status

      _turn3, loop3 = windowed_turn!("and last")
      third = round_request_entries(loop_node(loop3, "r1"))
      assert_equal canonical(second), canonical(third).first(second.length),
        "a turn with no lead after one with a lead: the earlier request whole"
      assert_equal [["reasoning"], ["assistant", "Mock: next done"], ["user", "and last"]],
        shape(third).drop(second.length)
      assert_equal 1, canonical(third).join.scan("/w2.").length, "never duplicated, never dropped"
    end
  end

  # A template's own post-history inline is per-turn text too: the turn seals it as the macros
  # rendered it, and the next turn replays it at its place instead of rendering it away.
  test "a post-history template inline is sealed with the turn and replayed in place" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      declared = Users::DeclareConfiguration.call(user: @agent, tool_definitions: [READ_TOOL],
        approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "assembly", compaction_policy: nil,
        prompt_template: { "blocks" => [
          { "type" => "slot", "slot" => "system_prompt" }, { "type" => "history" },
          { "type" => "inline", "role" => "developer", "text" => "Answer in one line." }, { "type" => "input" },
        ] })
      assert_equal :declared, declared.outcome
      turn1, loop1 = windowed_turn!("read the notes")
      run_loop_round!(loop1, sse_success("the notes, read", reasoning: "plan", reasoning_encrypted: "blob-one"))
      converge!
      assert_equal "completed", turn1.reload.status
      first = round_request_entries(loop_node(loop1, "r1"))

      _turn2, loop2 = windowed_turn!("and next")
      second = round_request_entries(loop_node(loop2, "r1"))

      assert_equal canonical(first), canonical(second).first(first.length),
        "turn 1's request whole, its template inline at its place"
      assert_equal [["reasoning"], ["assistant", "Mock: the notes, read"], ["developer", "Answer in one line."],
                    ["user", "and next"]], shape(second).drop(first.length)
      assert_equal [["developer", "Answer in one line."], ["user", "read the notes"]], shape(second).first(2),
        "once per turn that carried it"
    end
  end

  # A template that leads with the per-turn text keeps its own prefix policy: nothing ahead of
  # history is sealed, so an identical lead extends the earlier request and never rides twice.
  test "a lead-first template keeps its own prefix: an identical lead extends turn 1 and is never duplicated" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      declared = Users::DeclareConfiguration.call(user: @agent, tool_definitions: [READ_TOOL],
        approval_mode: "bypass", approval_rules: nil, prompt_mechanism: "assembly", compaction_policy: nil,
        prompt_template: { "blocks" => [
          { "type" => "slot", "slot" => "system_prompt" }, { "type" => "lead" }, { "type" => "history" },
          { "type" => "input" },
        ] })
      assert_equal :declared, declared.outcome
      turn1, loop1 = windowed_turn!("read the notes", context_options: lead_options("env block"))
      run_loop_round!(loop1, sse_success("the notes, read", reasoning: "plan", reasoning_encrypted: "blob-one"))
      converge!
      first = round_request_entries(loop_node(loop1, "r1"))
      assert_nil turn1.reload.active_variant.content_bodies.find_by(role: "preface"), "nothing behind history"

      _turn2, loop2 = windowed_turn!("and next", context_options: lead_options("env block"))
      second = round_request_entries(loop_node(loop2, "r1"))

      assert_equal canonical(first), canonical(second).first(first.length)
      assert_equal [["reasoning"], ["assistant", "Mock: the notes, read"], ["user", "and next"]],
        shape(second).drop(first.length)
      assert_equal 1, canonical(second).join.scan("env block").length, "the lead leads once"
    end
  end

  # An edit replaces the ANSWER: the edited variant carries the turn's question — its words and
  # the per-turn text they were asked behind — so later history renders the question as it was sent.
  test "an edited answer keeps the turn's preface: later history renders its lead, its words, the edit" do
    declare_tools!(@agent)
    turn1, loop1 = materialize_loop_reply!(@conversation, agent: @agent, text: "read the notes",
      context_options: lead_options)
    schedule_loop!(loop1)
    run_loop_round!(loop1, sse_success("the notes, read"))
    converge!
    assert_equal "completed", turn1.reload.status

    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation.reload, turn_public_id: turn1.public_id,
      entries: [{ "text" => "the notes, edited" }], acting_user: @human
    ))
    assert_predicate edited, :accepted?, edited.outcome.to_s
    assert_equal preface_payloads(loop1.conversation_turn_variant), preface_payloads(edited.value),
      "the edited variant carries the preface its question was asked behind"

    _turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: "and next")
    schedule_loop!(loop2)
    assert_equal [["developer", LEAD], ["user", "read the notes"], ["assistant", "the notes, edited"], ["user", "and next"]],
      shape(round_request_entries(loop_node(loop2, "r1")))
  end

  # ── Replay on a windowed lane: every round's thinking, one default for every seed path ──

  # REASONING IS HISTORY: every trace the target can read rides on every later request exactly as
  # the request that first carried it did, until its TURN leaves the window. No trace budget, no
  # trace-only cut: traces and history share one fit, and the one cut is the timeline compaction
  # (or the author's own `off`-slide, which drops turns with their traces).
  def thinking_turn_one!(agent_run, first:, second:)
    run_loop_round!(agent_run, thought("calling", "blob-1a", tokens: first, tool_calls: [
      { id: "call_a", name: "read_file", arguments: "{\"path\":\"a\"}" },
    ]))
    settled = AgentRuns::Parks::Settle.call(node: agent_run.agent_run_tasks.find_by!(tool_call_id: "call_a"),
      trusted: true, content: "contents of a", outcome: "completed")
    assert_predicate settled, :applied?
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, thought("read", "blob-1b", tokens: second))
    converge!
    assert_equal "completed", agent_run.conversation_turn.reload.status
  end

  test "every trace replays until its turn leaves the window" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: FIT_WINDOW)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      thinking_turn_one!(loop1, first: 100, second: 300)

      _turn2, loop2 = windowed_turn!("and the rest")
      assert_equal %w[blob-1a blob-1b], replayed_blobs(round_request_entries(loop_node(loop2, "r1"))),
        "turn 2 replays every trace turn 1 carried, not only its last round's"
      run_loop_round!(loop2, thought("the rest", "blob-2", tokens: 300))
      converge!

      _turn3, loop3 = windowed_turn!("and more")
      assert_equal %w[blob-1a blob-1b blob-2], replayed_blobs(round_request_entries(loop_node(loop3, "r1"))),
        "every earlier round's thinking, whole"
    end
  end

  test "history and traces past the fit arm the summary; no trace is omitted and sent" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: FIT_WINDOW)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      thinking_turn_one!(loop1, first: 100, second: 1_700)
      _turn2, loop2 = windowed_turn!("and the rest")
      assert_equal %w[blob-1a blob-1b], replayed_blobs(round_request_entries(loop_node(loop2, "r1")))
      run_loop_round!(loop2, thought("the rest", "blob-2"))
      converge!

      head = post_input!(@conversation, acting_user: @agent, kind: "direct_reply", text: "and more",
        provider_id: "dev", model_ref: WINDOWED)
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

      summary = @conversation.conversation_turns.find_by!(kind: "compaction_summary")
      assert_equal "running", summary.status, "the fit wall arms the timeline compaction"
      assert_equal "pending", head.reload.state, "and the head waits behind it"
      assert_equal 2, @conversation.conversation_turns.where(kind: "direct_reply").count,
        "no reply ran with a trace left out"
    end
  end

  # THE AUTHOR'S `off`: no summary can be armed, so the request slides — the oldest run drops WITH
  # its traces, to both bounds — and the next turn cut at the same place extends it.
  test "under off the slide drops the oldest run with its traces, and the next turn extends" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: FIT_WINDOW)) do
      declare_tools!(@agent, compaction_policy: { "mode" => "off" })
      _turn1, loop1 = windowed_turn!("read the notes")
      thinking_turn_one!(loop1, first: 100, second: 1_700)
      _turn2, loop2 = windowed_turn!("and the rest")
      run_loop_round!(loop2, thought("the rest", "blob-2"))
      converge!

      turn3, loop3 = windowed_turn!("and more")
      third = round_request_entries(loop_node(loop3, "r1"))
      assert_equal %w[blob-2], replayed_blobs(third), "the slide dropped turn 1 whole, its traces with it"
      assert_equal ["user", "and the rest"], shape(third).first, "the cut is a leading run"
      run_loop_round!(loop3, thought("more", "blob-3", tokens: 200))
      converge!
      assert_equal "completed", turn3.reload.status

      _turn4, loop4 = windowed_turn!("and last")
      fourth = round_request_entries(loop_node(loop4, "r1"))
      assert_equal canonical(third), canonical(fourth).first(third.length), "cut at the same place, it extends"
      assert_equal %w[blob-2 blob-3], replayed_blobs(fourth)
    end
  end

  # Regeneration re-asks under the default a person's turn reads: the reassembly branch's rebuilt
  # round one replays every earlier round's thinking on a windowed target, as the send it re-asks did.
  test "a regenerated answer re-asked on a windowed lane replays every earlier round's thinking" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      two_thinking_rounds!(loop1)
      turn2, loop2 = materialize_loop_reply!(@conversation, agent: @agent, text: "and next")
      schedule_loop!(loop2)
      run_loop_round!(loop2, sse_success("next, done"))
      converge!
      assert_equal "completed", turn2.reload.status

      result = regenerate!(turn2, provider_id: "dev", model_ref: WINDOWED)
      assert_predicate result, :accepted?, result.outcome.to_s
      sibling_loop = result.value.agent_run
      schedule_loop!(sibling_loop)
      assert_equal %w[blob-one blob-two], replayed_blobs(round_request_entries(loop_node(sibling_loop, "r1"))),
        "another model re-asks through the reassembly branch, under the target row's default"
    end
  end

  # The estimate models the send: its rendered entries are the entries the drain seals, so on a
  # windowed lane it prices every round's thinking the send will carry.
  test "the estimate on a windowed lane renders the thinking the send replays, entry for entry" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      two_thinking_rounds!(loop1)

      estimate = Conversations::ContextEstimate.call(Conversations::ContextEstimate::Command.new(
        conversation: @conversation.reload, acting_user: @agent, provider_id: "dev", model_ref: WINDOWED,
        reasoning_effort: nil, request_options: nil, prompt: "and next", history_max_entries: nil,
        history_token_budget_share: nil, reasoning_replay_mode: nil, inline: nil, render: true
      ))
      assert_predicate estimate, :accepted?, estimate.outcome.to_s
      rendered = estimate.value.rendered.entries
      _turn2, loop2 = windowed_turn!("and next")
      sent = round_request_entries(loop_node(loop2, "r1"))

      assert_equal %w[blob-one blob-two], replayed_blobs(rendered)
      assert_equal canonical(sent), canonical(rendered), "the preview's entries are the send's"
    end
  end

  # A trace another model produced carries nothing on the target's wire — no blob and no fence —
  # so the switch is ONE edit at the first earlier trace (a new model is a new cache), and from the
  # switch on the requests on that target extend each other.
  test "after a model switch nothing of the earlier reasoning rides on the other model, and later turns extend" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      two_thinking_rounds!(loop1)

      turn2, loop2 = windowed_turn!("and next", model_ref: WINDOWED_OTHER)
      second = round_request_entries(loop_node(loop2, "r1"))
      assert_empty replayed_blobs(second), "a blob never crosses a model boundary"
      assert_not_includes second.to_json, "plan one", "nor its summary, as words"
      assert_not_includes second.to_json, "<think>"
      run_loop_round!(loop2, thought("next, done", "blob-other"))
      converge!
      assert_equal "completed", turn2.reload.status

      _turn3, loop3 = windowed_turn!("and last", model_ref: WINDOWED_OTHER)
      third = round_request_entries(loop_node(loop3, "r1"))
      assert_equal canonical(second), canonical(third).first(second.length),
        "on the same target the requests extend from the switch on"
      assert_equal %w[blob-other], replayed_blobs(third), "the target's own thinking replays"
    end
  end

  # THE EXCEPTION the monotone default names: a turn that asked for a narrower mode by name left
  # traces out that the next default turn replays again. Pinned as it stands, beside the ledger's
  # row on per-input options a later turn does not carry.
  test "an explicit narrower mode narrows its own turn only: the next default turn replays every trace" do
    ModelCatalog.stub(:current, DevModelLane.windowed_catalog(input_tokens: 8_192)) do
      declare_tools!(@agent)
      _turn1, loop1 = windowed_turn!("read the notes")
      two_thinking_rounds!(loop1)

      turn2, loop2 = windowed_turn!("and next", context_options: { "reasoning_replay" => { "mode" => "last_turn" } })
      assert_equal %w[blob-two], replayed_blobs(round_request_entries(loop_node(loop2, "r1")))
      run_loop_round!(loop2, sse_success("next, done"))
      converge!
      assert_equal "completed", turn2.reload.status

      _turn3, loop3 = windowed_turn!("and last")
      assert_equal %w[blob-one blob-two], replayed_blobs(round_request_entries(loop_node(loop3, "r1"))),
        "the default turn puts back the trace the explicit one left out"
    end
  end
end
