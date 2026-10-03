require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Pruning clears consumed results while preserving the current fan and the sealed continuation.
class Conversations::Compaction::PruneTest < ActiveJob::TestCase
  include CompactionTestHelper

  # ════════════════════════════════════════════════════════════════════ THE PRUNE ARM, THE SHARED
  # TAIL, THE CHOICE ONCE PER WALL
  # ════════════════════════════════════════════════════════════════════

  # Round one spoke at length and read a file; round two read another and
  # said little; round three does not fit. The prune arm's arithmetic on
  # THIS shape: the overshoot is a few hundred tokens, the tail rule keeps
  # round two verbatim (its ≈ 8 KB of request bytes sit inside a quarter
  # of the ≈ 38 KB total — the oldest round never joins) and round one's
  # result alone covers the overshoot — so the cheaper repair is chosen,
  # the round composes from rows and goes in the SAME pass.
  def pruned_loop!(**over)
    conversation, turn, agent_loop = loop_backed_two_reads!(
      first_words: prose(22_000), first_body: "first line: alpha\n#{prose(8_000)}",
      second_words: "noted", second_body: "first line: beta\n#{prose(8_000)}", **over
    )
    schedule_loop!(agent_loop)
    [conversation, turn, agent_loop]
  end

  test "prune is chosen when the results outside the tail cover the overshoot, and summarize when they do not" do
    conversation, _turn, agent_loop = pruned_loop!
    r3 = loop_node(agent_loop, "r3")

    assert_equal "r2", r3.compaction["pruned_before"],
      "the mark names the first tail round: everything chain-before it composes cleared"
    assert_nil r3.compaction["summary_source"], "one repair per wall, never both"
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "k1"), "a prune appends nothing"
    assert_equal "running", r3.status, "the round that walled was re-scheduled in the pass that pruned it"
    item = compacted_item(conversation)
    assert_equal "prune", item.payload["mode"]
    assert_equal "wall", item.payload["trigger"]
    assert_equal "r3", item.payload["task_key"]
    refute item.payload.key?("summary_task_key"), "nothing was authored"
    assert_equal agent_loop.conversation_turn.public_id, item.payload["turn_public_id"]

    texts = request_texts(r3)
    results = texts.select { |kind, _| kind == "result" }.map(&:last)
    assert_equal 2, results.length
    assert_equal AgentLoops::RoundReplay::Pairing::CLEARED, results.first,
      "round one's result is the placeholder: the call stays, the bytes go"
    assert results.last.start_with?("first line: beta"), "round two's result rides verbatim — it is the tail"
    assert_equal 1, texts.count { |_, text| text == AgentLoops::RoundReplay::Pairing::CLEARED }
    refute_includes texts.flatten.join, "first line: alpha", "not one byte of a cleared result"
    assert_includes texts.flatten.join, "Mock: #{prose(22_000)[0, 40]}", "words are never pruned, only results"

    # THE SAME SHAPE WITH NOTHING TO PRUNE summarizes: two hundred bytes of
    # results cannot cover an overshoot of hundreds of tokens.
    conversation, _turn, agent_loop = loop_backed_two_reads!(
      first_words: prose(22_000), first_body: "first line: alpha\n",
      second_words: prose(22_000), second_body: "first line: beta\n"
    )
    schedule_loop!(agent_loop)
    r3 = loop_node(agent_loop, "r3")
    assert_equal "k1", r3.compaction["summary_source"]
    assert_nil r3.compaction["pruned_before"]
    assert_equal "kernel", compacted_item(conversation).payload["mode"]
    assert_equal "k1", compacted_item(conversation).payload["summary_task_key"]
  end

  # The next wall of a pruned loop: one more read behind `words`, then
  # the scheduler pass that reaches the wall and arms the repair.
  def wall_after_prune!(agent_loop, call_id, words: "noted", body: "first line: #{call_id}\n#{prose(8_000)}")
    read!(agent_loop, call_id, "docs/#{call_id}.txt", words, body)
    schedule_loop!(agent_loop)
  end

  def compacted_modes(conversation)
    conversation.conversation_event_items.where(item_type: "context_compacted").order(:id).map { |item| item.payload["mode"] }
  end

  # The arm counts nothing: a wall whose uncleared results outside the
  # tail still cover the overshoot prunes, however many prunes the chain
  # already carries. After round three's prune (round one's result
  # cleared), round four walls with round two's ≈ 8 KB result outside
  # the tail (round three joins it) against an overshoot of a few KB.
  test "a wall whose prunable results still cover the overshoot prunes, whatever came before" do
    conversation, _turn, agent_loop = pruned_loop!
    assert_equal "r2", loop_node(agent_loop, "r3").compaction["pruned_before"], "the first wall prunes"

    wall_after_prune!(agent_loop, "call_c")
    r4 = loop_node(agent_loop, "r4")
    assert_equal "r3", r4.compaction["pruned_before"], "the second wall prunes too: round two's result covers it"
    assert_nil r4.compaction["summary_source"]
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "k1"), "nothing summarizes while the results cover the wall"
    assert_equal %w[prune prune], compacted_modes(conversation)
  end

  # THE WALL THAT EXHAUSTS ITS PRUNABLE RESULTS SUMMARIZES, after prunes:
  # the same pruned loop, then round three answers at length (≈ 22 KB of
  # words, never prunable) over a 20-byte result. Round four's wall
  # overshoots by ≈ 19 KB; nothing joins the tail (round three's words
  # exceed its quarter) and the uncleared results outside it — round two's
  # ≈ 8 KB, round three's 18 bytes — cannot cover it, so the kernel's
  # summarizer is appended and no second mark is written.
  test "the wall that exhausts its prunable results summarizes, after prunes" do
    conversation, _turn, agent_loop = pruned_loop!(compaction_policy: { "mode" => "kernel" })
    assert_equal "r2", loop_node(agent_loop, "r3").compaction["pruned_before"], "the first wall prunes"

    wall_after_prune!(agent_loop, "call_c", words: prose(22_000), body: "first line: gamma\n")
    r4 = loop_node(agent_loop, "r4")
    assert_equal "k1", r4.compaction["summary_source"], "the results outside the tail cannot cover this wall"
    assert_nil r4.compaction["pruned_before"], "one repair per wall, never both"
    assert_equal "model_task", node(agent_loop, "k1").task_kind
    assert_equal %w[prune kernel], compacted_modes(conversation)
    assert_equal({ "mode" => "kernel", "summary_source" => "k1" }, r4.compaction, "the policy beside the mark, nothing else")
  end

  # A PRUNE COVERS THE OVERSHOOT NET OF THE PLACEHOLDERS IT LEAVES: each
  # cleared call still costs the wire `Pairing::CLEARED` (89 bytes), so a
  # result of 100 bytes frees 11. Against an overshoot of 50 the gross
  # would prune — and the pruned round would still not fit, fenced by its
  # own mark from a second repair — so the arm summarizes; against an
  # overshoot of 11 (the net itself) it covers and the arm prunes. Driven through
  # the arm's own door on an unrepaired round, the number in hand.
  test "a prune must cover the overshoot net of the placeholders it leaves" do
    cleared = Conversations::Compaction::Serialize::CLEARED_BYTES
    assert_operator cleared, :<, 100, "the placeholder is shorter than the result it replaces"

    conversation, _turn, agent_loop = consumed_read_before_prune!
    r3 = loop_node(agent_loop, "r3")
    repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: r3,
      trigger: Conversations::Compaction::Trigger.wall(r3, overshoot: Conversations::Compaction::Overshoot.bytes(50)))
    assert_equal "kernel", repair.mode, "100 bytes of result free #{100 - cleared} on the wire: not the 50 the wall needs"
    assert_equal "k1", repair.summary_task_key
    r3.reload
    assert_equal "k1", r3.compaction["summary_source"]
    assert_nil r3.compaction["pruned_before"]
    assert_equal "model_task", node(agent_loop, "k1").task_kind
    assert_equal "kernel", compacted_item(conversation).payload["mode"]

    # THE CONTROL: the same round against an overshoot the net covers prunes.
    _conversation, _turn, control = consumed_read_before_prune!
    r3 = loop_node(control, "r3")
    repair = Conversations::Compaction::Arm.call(agent_loop: control, node: r3,
      trigger: Conversations::Compaction::Trigger.wall(r3, overshoot: Conversations::Compaction::Overshoot.bytes(100 - cleared)))
    assert_predicate repair, :pruned?
    assert_equal "r2", r3.reload.compaction["pruned_before"], "the mark keeps the fan being read for the first time"
    assert_nil r3.compaction["summary_source"]
    assert_nil control.agent_loop_nodes.find_by(node_key: "k1")
    schedule_loop!(control)
    outputs = round_request_entries(r3.reload).select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["call_a", AgentLoops::RoundReplay::Pairing::CLEARED], ["call_b", "fresh" * 1_000]],
      outputs.map { |entry| entry.fetch("payload").values_at("call_id", "output") }
  end

  def consumed_read_before_prune!
    conversation, turn, agent_loop = loop_backed_read!(body: "x" * 100, words: "a short read",
      compaction_policy: { "mode" => "kernel" })
    schedule_loop!(agent_loop)
    assert_includes round_request_entries(loop_node(agent_loop, "r2")).map { |entry| entry.dig("payload", "output") },
      "x" * 100, "the old result was actually consumed before it becomes eligible for clearing"
    read!(agent_loop, "call_b", "docs/current.txt", "another short read", "fresh" * 1_000)
    history = Conversations::Compaction::Serialize.loop_history(loop_node(agent_loop, "r3"))
    assert_equal history.rounds.length, history.tail_index, "the current fan exceeds the unchanged tail budget"
    [conversation, turn, agent_loop]
  end

  # The mark is the fence on this arm too: a pruned round that walls again
  # is "compacting a compaction", and the round fails on size honestly.
  test "a pruned round is never armed again" do
    _conversation, _turn, agent_loop = pruned_loop!
    r3 = loop_node(agent_loop, "r3")

    refute Conversations::Compaction::Arm.armable?(r3)
    assert_equal :already_compacted, Conversations::Compaction::Arm.refusal_for_round(r3)
    assert_not Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: r3,
      trigger: Conversations::Compaction::Trigger.wall(r3,
        overshoot: Conversations::Compaction::Overshoot.bytes(10)))
    assert_equal "r2", r3.reload.compaction["pruned_before"], "no second mark"
    assert_nil r3.compaction["summary_source"]
    assert_equal 3, agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name).count
  end

  # THE PREFIX AFTER A PRUNE: the pruned round's own sealed body is the byte-stable prefix its
  # continuation replays — and the mark is per-round, so the continuation composes from the sealed
  # body, never from rows again (which would bust the prefix every round).
  test "the continuation of a pruned round replays its sealed request byte for byte and inherits no mark" do
    _conversation, _turn, agent_loop = pruned_loop!
    r3 = loop_node(agent_loop, "r3")
    r3_request = round_request_entries(r3)

    read!(agent_loop, "call_c", "docs/more.txt", "one more", "first line: gamma\n")
    schedule_loop!(agent_loop)
    r4 = loop_node(agent_loop, "r4")

    assert_equal "running", r4.status
    assert_nil r4.compaction, "`Step.inheriting` drops the mark with the summary mark"
    assert_equal r3_request, round_request_entries(r4).first(r3_request.length),
      "the pruned round's request IS the prefix: the same bytes, then what it said"
    assert_includes request_texts(r4).flatten.join, "first line: gamma", "the new tail rides verbatim"
    assert_equal 1, request_texts(r4).count { |_, text| text == AgentLoops::RoundReplay::Pairing::CLEARED },
      "the cleared result stays cleared; nothing else was touched"
  end

  # HISTORY HONOURS THE MARK: the next turn renders the cleared round's results as the placeholder
  # and the tail's verbatim, so what the model read after the prune is what history shows — and the
  # next turn's prefix equals the pruned round's own request through its last message so the shared
  # prefix remains cacheable.
  test "the next turn's history renders the pruned round as it was read, and its prefix is byte-stable" do
    conversation, turn, agent_loop = pruned_loop!(text: "the question")
    r3 = loop_node(agent_loop, "r3")
    r3_request = round_request_entries(r3)
    run_loop_round!(agent_loop, sse_success("all read"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    segments = Conversations::ContextAssembly::ChatHistory.call(conversation: conversation.reload).segments
    rounds = segments.select { |segment| segment.result_items.any? }
    assert_equal 2, rounds.length
    assert_equal [AgentLoops::RoundReplay::Pairing::CLEARED],
      rounds.first.result_items.map { |item| item.payload["output"] }
    assert rounds.last.result_items.sole.payload["output"].start_with?("first line: beta")

    post_input!(conversation, acting_user: @human, text: "and now the rest")
    _turn2, loop2 = materialize_loop_reply!(conversation, agent: @agent, text: nil)
    schedule_loop!(loop2)
    next_request = round_request_entries(loop_node(loop2, "r1"))

    assert_equal r3_request, next_request.first(r3_request.length),
      "turn N+1's prefix is turn N's pruned request, byte for byte, then what followed — " \
        "the seed merges into the same user message the prompt rode in"
    refute_includes next_request.to_json, "first line: alpha"
  end

  # The marks change nothing the serializer renders. A summarize after a prune reads the same
  # pointers it would have read before it — the serializer never carried bodies — and the composer's
  # cleared rendering is the placeholder, so no reader sees a value the model did not.
  test "the serializer renders a pruned round exactly as an unpruned one, and the composer clears it" do
    _conversation, _turn, agent_loop = pruned_loop!
    r1 = loop_node(agent_loop, "r1")
    fan = AgentLoops::RoundReplay.fans_of([r1]).fetch(r1.id)
    entries = Conversations::Compaction::Serialize.loop_entries(loop_node(agent_loop, "r3"))

    assert_equal Conversations::Compaction::Serialize.render_round(r1, fan), entries.first
    assert_includes entries.first, "not carried; re-read it if needed"
    refute_includes entries.first, "first line: alpha"
    cleared = AgentLoops::RoundReplay.call(r1, fan_by_call_id: fan, cleared: true).result_items
    assert_equal [AgentLoops::RoundReplay::Pairing::CLEARED], cleared.map { |item| item.payload["output"] }
  end

  # THE CUT MARKER ON THE ROUND PROJECTION: a reader draws the line from the marks, never from a row
  # of its own.
  test "the round projection carries compacted_before and pruned_before by presence" do
    _conversation, _turn, agent_loop = pruned_loop!
    rows = AgentLoops::Transcript.turn_rounds([agent_loop]).fetch(agent_loop.id).index_by { |row| row[:task_key] }
    assert_equal "r2", rows.fetch("r3")[:pruned_before]
    refute rows.fetch("r1").key?(:pruned_before)
    refute rows.fetch("r3").key?(:compacted_before)

    repaired = loop_with_history
    schedule!(repaired)
    run!(repaired, "k1", "a summary")
    rows = AgentLoops::Transcript.turn_rounds([repaired]).fetch(repaired.id).index_by { |row| row[:task_key] }
    assert_equal "round2", rows.fetch("round2")[:compacted_before],
      "this round read a summary in place of everything before it"
    refute rows.fetch("round1").key?(:compacted_before)
  end

  # A CLEARED ROUND CLEARS RESULTS, NOT FAILURES. A call that settled without a result has only the
  # kernel's small error envelope, so clearing it frees nothing — and the placeholder says a result
  # existed and was dropped, which reads as success. The prune arm keeps the envelope, and its
  # arithmetic agrees: such a call is never counted as something a prune frees.
  test "a prune keeps a failed call's error envelope, and never counts it as freed" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    post_input!(conversation, acting_user: @human, text: "read the index")
    _turn, agent_loop = materialize_loop_reply!(conversation, agent: @agent, text: nil)
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success(prose(22_000), tool_calls: [
      { id: "call_a", name: "read_file", arguments: %({"path":"docs/index.txt"}) },
      { id: "call_x", name: "write_file", arguments: %({"path":"docs/index.txt"}) },
    ]))
    failed = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_x")
    assert_equal %w[failed unknown_tool], [failed.status, failed.error_key], "never declared, so it never ran"
    AgentLoops::Parks::Settle.call(node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a"), trusted: true,
      content: "first line: alpha\n#{prose(8_000)}", is_error: false, outcome: "completed")
    schedule_loop!(agent_loop)
    assert_equal "running", loop_node(agent_loop, "r2").status, "round two fits — the wall is round three's"
    read!(agent_loop, "call_b", "docs/notes.txt", "noted", "first line: beta\n#{prose(8_000)}")

    history = Conversations::Compaction::Serialize.loop_history(continuation_of(agent_loop))

    schedule_loop!(agent_loop)
    r3 = loop_node(agent_loop, "r3")
    assert_equal "r2", r3.compaction["pruned_before"], "round one is cleared"
    results = round_request_entries(r3).select { |p| p["type"] == "tool_result_item" }.map { |p| p["payload"] }
      .index_by { |p| p["call_id"] }
    assert_equal AgentLoops::RoundReplay::Pairing::CLEARED, results.fetch("call_a")["output"]
    assert_equal AgentLoops::RoundReplay::Pairing.output_for(failed), results.fetch("call_x")["output"],
      "the failure is still the envelope the model read before the prune"
    assert results.fetch("call_x")["is_error"], "and still flagged as an error"

    alpha = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a").content_bodies.find_by!(role: "output")
    assert_equal alpha.byte_size - Conversations::Compaction::Serialize::CLEARED_BYTES, history.prunable_bytes,
      "only the result frees anything; the failure costs its envelope either way"
  end

  # The prune arm reads `rounds` and `entries` index-aligned (`LoopHistory`):
  # the seed is FOLDED into round one's entry, never prepended as one of
  # its own, or the tail index would land on the wrong round.
  test "the prune arm's tail index is unmoved by the seed" do
    _conversation, _turn, agent_loop = pruned_loop!(text: "the question")

    history = Conversations::Compaction::Serialize.loop_history(loop_node(agent_loop, "r3"))

    assert_equal history.rounds.length, history.entries.length
    assert_equal "r1", history.rounds.first.node_key
    assert history.entries.first.include?("User:\nthe question"), "the seed rides inside round one's entry"
    assert_equal "r2", history.rounds.fetch(history.tail_index).node_key
  end

  # ONE TAIL RULE, TWO UNITS. The rule — a quarter of the total, 80 KB at most, newest first, the
  # oldest never joins — is one; the unit is each arm's own. The summarizer cuts its RENDERING,
  # where a 46 KB result is a 300-byte pointer; the prune arm cuts REQUEST bytes, the bytes a
  # round's results cost the composed request. Measured on the rendering, "80 KB" kept 15–29 whole
  # results ≈ 0.6–0.75 MB verbatim on every Long, and the post-prune floor ratcheted. The byte wall
  # is the only wall a windowless lane has, so it is the wall here.
  test "the prune arm's tail is measured in request bytes, never on the pointer rendering" do
    conversation, _turn, agent_loop = loop_backed_read!(body: read_result, model_ref: "mock-windowless")
    walled = nil
    2.upto(40) do |number|
      schedule_loop!(agent_loop)
      round = continuation_of(agent_loop)
      break walled = round if round.pruned_before

      assert_equal "running", round.status, "r#{number} fits — no wall yet"
      read!(agent_loop, "call_#{number}", "docs/#{number}.txt", "read #{number}", read_result)
    end
    assert_not_nil walled, "twenty-odd 46 KB results cross the 1 MiB byte wall"
    assert_equal "running", walled.status, "pruned, and re-scheduled in the same pass"
    assert_equal "prune", compacted_item(conversation).payload["mode"]

    history = Conversations::Compaction::Serialize.loop_history(walled)
    assert_operator history.rounds.length, :>=, 20
    tail = history.rounds.drop(history.tail_index)
    assert_equal 1, tail.length, "80 KB of request bytes holds ONE 46 KB result, never two"
    assert_equal history.rounds[history.tail_index].node_key, walled.pruned_before,
      "the mark names the first tail round — the newest round whose result still rides"

    results = request_texts(walled).select { |kind, _| kind == "result" }.map(&:last)
    assert_equal history.rounds.length, results.length, "every call keeps its result slot"
    assert_equal 1, results.count { |text| text.start_with?("first line:") }, "exactly one whole result rides"
    assert results.last.start_with?("first line:"), "and it is the newest"
    assert_equal results.length - 1, results.count(AgentLoops::RoundReplay::Pairing::CLEARED)

    # The summarizer's own cut is untouched: over the pointer rendering the same rule keeps more
    # rounds than the prune arm does, because a pointer is a line and a result is a body (pointers
    # never values).
    _older, kept = Conversations::Compaction::Serialize.call(history.entries)
    assert_operator kept.scan(/^## Round /).length, :>, tail.length
    refute_includes kept, "first line:", "not one byte of a result reaches the summarizer"
  end

  # THE SUMS ARE COLUMN READS: the prune arm's arithmetic — what it could clear, what each round
  # costs the request — is answered by ONE SQL sum over `content_bodies.byte_size`, never by loading
  # a body, and equals the loaded text byte for byte.
  test "the arm's byte sums are answered by the stored column — one SUM, no body loaded, equal to the text" do
    _conversation, _turn, agent_loop = pruned_loop!
    r3 = loop_node(agent_loop, "r3")

    history = nil
    assert_queries_match(/SUM\("content_bodies"\."byte_size"\)/, count: 1) do
      history = Conversations::Compaction::Serialize.loop_history(r3)
    end
    assert_no_queries { [history.prunable_bytes, history.request_sizes, history.tail_index] }

    first_result = agent_loop.agent_loop_nodes.find_by!(tool_call_id: "call_a").content_bodies.find_by!(role: "output")
    cleared = Conversations::Compaction::Serialize::CLEARED_BYTES
    assert_equal first_result.byte_size - cleared, history.prunable_bytes,
      "round one's result, net of the placeholder its call keeps, is what a prune frees"
    assert_equal first_result.effective_text.bytesize - cleared, history.prunable_bytes
    loaded = history.rounds.map do |round|
      fan = history.fans.fetch(round.id, {})
      Conversations::Compaction::Serialize.body_text(round, "output").bytesize + fan.values.sum do |tool|
        JSON.generate(tool.tool_input).bytesize + Conversations::Compaction::Serialize.body_text(tool, "output").bytesize
      end
    end
    assert_equal loaded, history.request_sizes, "answer + calls + results per round, from the column"
    assert_includes history.entries.first,
      "#{ActiveSupport::NumberHelper.number_to_delimited(first_result.byte_size)} bytes, not carried",
      "the pointer's count is the same column"
  end
end
