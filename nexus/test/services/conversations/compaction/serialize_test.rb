require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

# Summary input preserves call provenance and pointers within the rendering and envelope bounds.
class Conversations::Compaction::SerializeTest < ActiveJob::TestCase
  include CompactionTestHelper

  # ════════════════════════════════════════════════════════════════════
  # ONE SERIALIZE OVER ENTRIES, ONE TRIGGER
  # ════════════════════════════════════════════════════════════════════

  # TOOL OUTPUT IS A POINTER, NEVER A VALUE (the fabrication fix). The
  # 2 KB head this serializer once kept was the material a flash-tier
  # summariser paraphrased into fifty-two wrong "first lines": whatever
  # the summariser is handed can only reach the model as its paraphrase,
  # and a paraphrased value is a wrong value. So a result renders as the
  # call that produced it and how much came back — enough to re-read it,
  # nothing to misquote.
  test "a tool result renders as a pointer, and no byte of its body" do
    body = read_result
    _conversation, _turn, agent_run = run_backed_read!(body: body)

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole

    pointer = rendered.lines.find { |line| line.start_with?("Tool read_file") }
    assert_not_nil pointer, "the call is named, so the model can make it again"
    assert_includes pointer, "(completed, ok)"
    assert_includes pointer, %({"path":"docs/index.txt"}), "the arguments are the address"
    assert_includes pointer, "46,080 bytes, not carried"
    assert_includes pointer, "re-read it if needed"
    refute_includes rendered, body[0, 40], "not one byte of the result reaches the summariser"
    assert_operator rendered.bytesize, :<, 2.kilobytes, "one result costs one line"
    assert_includes rendered, "Mock: reading the index", "the assistant's own words stay verbatim"
  end

  # THE POINTER STATES THE OUTCOME BESIDE THE SIZE (Gate 3, 2026-09-10).
  # `→ 0 bytes` alone read the same for a call still running, one that
  # finished with nothing to say and one that failed; every real-model
  # summary took it as "may not have succeeded" and one re-ran the
  # command. The status word stays the row's own; an outcome word joins
  # it — and the pointer still carries no value.
  test "a tool that ran and errored renders as (completed, error), still without a byte of its body" do
    body = "boom: #{SecureRandom.hex(16)}"
    _conversation, _turn, agent_run = run_backed_read!(body: body, is_error: true)

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole
    pointer = rendered.lines.find { |line| line.start_with?("Tool read_file") }

    assert_includes pointer, "(completed, error)", "is_error is data the pointer states, never a value it carries"
    assert_includes pointer, "bytes, not carried; re-read it if needed"
    refute_includes rendered, body, "the error's text is a value too"
  end

  # THE POINTER SPELLS THE NAME THE MODEL USED: a call made under an alias is a row whose
  # `tool_name` is the kernel's wire name, and a pointer in that spelling would hand the summarizer
  # a name the model never saw.
  test "a call made under an alias renders as the alias, never the kernel's wire name" do
    agent_run = create_loop!(model("round1", "prompt" => "wait the work", "tools" => [WAIT_ALIAS]))
    apply_via(step_attempt(agent_run, "round1"), sse_success("composing", tool_calls: [
      { id: "call_w", name: "AwaitWork", arguments: %({"task":"round1"}) },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_w")
    assert_equal %w[wait AwaitWork], [call.tool_name, call.tool_alias], "the fixture is a real aliased row"

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole
    pointer = rendered.lines.find { |line| line.start_with?("Tool ") }

    assert_not_nil pointer
    assert pointer.start_with?("Tool AwaitWork ("), pointer
    refute_includes rendered, "Tool wait"
    # The head the envelope's `<call>` line writes, one helper for both: `>` raw, never `\u003e`.
    assert_includes pointer, %(: {"task":"round1"} → ), pointer
  end

  test "a tool still on its runner renders as (dispatched, no result yet)" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    post_input!(conversation, acting_user: @human, text: "read the index")
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule_loop!(agent_run)
    call_read!(agent_run, "call_a", "docs/index.txt", "reading the index")
    assert_equal "dispatched", agent_run.agent_run_tasks.find_by!(tool_call_id: "call_a").status

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole
    pointer = rendered.lines.find { |line| line.start_with?("Tool read_file") }

    assert_includes pointer, "(dispatched, no result yet)", "not yet is not nothing"
    assert_includes pointer, "0 bytes, not carried"
  end

  test "a tool that never ran renders as (failed, no result)" do
    _conversation, _turn, agent_run = run_backed_read!(body: "", outcome: "failed")
    assert_equal "failed", agent_run.agent_run_tasks.find_by!(tool_call_id: "call_a").status

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole
    pointer = rendered.lines.find { |line| line.start_with?("Tool read_file") }

    assert_includes pointer, "(failed, no result)", "the runner's own verdict, so a re-run is a decision, not a guess"
    assert_includes pointer, "0 bytes, not carried"
  end

  # A CALL FAILED FOR ITS SIZE, THEN A SUMMARY. The row stores none of the oversized arguments, and
  # replaying the model's own call in the next request is what walls it — so the continuation that
  # was to read the failure reads a summary instead, and the summary is written from pointers. The
  # pointer therefore carries the failure the model would have read, in the envelope's own words:
  # without it the summarizer sees `{} → 0 bytes`, and the repaired round learns at most that some
  # call failed, never why.
  test "a call failed for its size tells the summarizer why, in the words the model would have read" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    post_input!(conversation, acting_user: @human, text: "write the report")
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule_loop!(agent_run)
    big = { "path" => "docs/report.txt", "content" => "x" * 70_000 }.to_json
    run_loop_round!(agent_run, sse_success("writing it whole",
      tool_calls: [{ id: "call_big", name: "read_file", arguments: big }]))

    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_big")
    assert_equal %w[failed tool_input_too_large], [call.status, call.error_key]
    repaired = continuation_of(agent_run)
    assert_equal "k1", repaired.compaction["summary_source"], "replaying the oversized call walled the window"

    request = node(agent_run, "k1").content_bodies.find_by!(role: "input").effective_text
    envelope = AgentRuns::RoundReplay::Pairing.output_for(call)
    assert_includes envelope, "over the 65,536 bytes one tool call may carry", "the fixture is the sized failure"
    pointer = request.lines.find { |line| line.start_with?("Tool read_file") }
    assert_includes pointer, "(failed, no result)", "the pointer's grammar is unchanged"
    assert_includes request, "#{pointer}#{envelope}", "the failure the model would have read follows its pointer"
    refute_includes request, "x" * 100, "and still no byte of the arguments the row could not store"
  end

  # A FAILURE THE RUNNER REPORTED IS A VALUE. Its words are stored as the result body, and the row's
  # error detail is their first line, so a pointer that carried the detail would carry the runner's
  # output into a summary that is read instead of the history. The pointer keeps the typed failure —
  # what kind of failure it was — and leaves the runner's words behind, as it does every result body.
  test "a failure the runner reported leaves its words out of the pointer, and keeps its key" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent)
    post_input!(conversation, acting_user: @human, text: "read the index")
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("reading",
      tool_calls: [{ id: "call_r", name: "read_file", arguments: %({"path":"docs/index.txt"}) }]))
    call = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_r")
    settled = AgentRuns::Parks::Settle.call(node: call, trusted: true,
      content: "stale value 4471 from the runner's own output", outcome: "failed")
    assert_predicate settled, :applied?, settled.outcome.inspect
    call.reload
    assert_equal "failed", call.status
    assert_includes call.error_detail, "stale value 4471", "the fixture's detail is the runner's words"

    pointer = Conversations::Compaction::Serialize.pointer(call, 0)

    assert_includes pointer, "(#{call.error_key})", "the pointer still says what kind of failure it was"
    refute_includes pointer, "stale value 4471", "and never carries the runner's words"
  end

  # THE ENTRIES ARE THE ROUNDS. The timeline serializer reads a loop-backed turn as its mainline
  # rounds, each rendered by the one renderer the loop's own repair reads — never as the variant's
  # adopted content, which is the deliverable's last word and nothing before it.
  test "the timeline renders a loop-backed turn as its rounds, byte-identical to the loop's own" do
    body = read_result
    conversation, turn, agent_run = run_backed_read!(body: body, text: "read it please")
    from_loop = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole
    schedule_loop!(agent_run)
    run_loop_round!(agent_run, sse_success("the final word"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status

    entries = Conversations::Compaction::Serialize.timeline_entries(conversation.reload)

    assert_equal 3, entries.length, "the person's message, then one entry per round"
    assert_equal "User:\nread the index", entries.first
    assert_equal from_loop, entries[1], "one renderer, two producers, the same bytes"
    assert entries[1].start_with?("## Round r1\n\nUser:\nread it please\n\n"),
      "round one opens with the turn's own words — its seed, never the request JSON"
    assert_includes entries[1], "46,080 bytes, not carried"
    assert entries.last.start_with?("## Round "), "the continuation is its own entry"
    assert_includes entries.last, "Mock: the final word"
    joined = entries.join("\n\n")
    assert_equal 1, joined.scan("Mock: the final word").length,
      "the adopted content is the deliverable's word, rendered as its round and never again"
    refute_includes joined, body[0, 40]
  end

  # THE SEED IS THE ROUND-ONE `User:`. An assembled round one's `input` body is the whole request as
  # message entries — no top-level text — so the summarizer used to be handed the ENTIRE prefix as
  # canonical JSON under `User:`, once per loop-backed turn, and the person's own words only buried
  # inside it. The turn's prompt body is the seed both producers render there instead.
  test "the summarizer's round-one entry is the seed, never the request JSON" do
    _conversation, _turn, agent_run = run_backed_read!(body: read_result, text: "read the index please")

    rendered = Conversations::Compaction::Serialize.loop_entries(continuation_of(agent_run)).sole

    assert_includes rendered, "User:\nread the index please", "the person's words, as the round's own prompt"
    refute_includes rendered, '"role":"user"', "not one byte of the assembled request's JSON"
    refute_includes rendered, '"parts"'
  end

  test "a plain reply turn's entry is its seed then its answer, one entry" do
    build_history!(turns: 1, hex: 8)
    accept!(kind: "direct_reply", text: "what now", provider_id: "dev", model_ref: "mock-text")
    drain!
    settle_reply!("here is the answer")

    entries = Conversations::Compaction::Serialize.timeline_entries(@conversation.reload)

    assert_equal "User:\nwhat now\n\nAssistant:\nMock: here is the answer", entries.last,
      "one entry per turn, so the tail rule still cuts on turn boundaries"
    assert_equal 2, entries.length
  end

  test "the between-turn summarizer is handed the person's words" do
    build_history!
    accept!(kind: "direct_reply", text: "what now", provider_id: "dev", model_ref: "mock-text")
    drain!
    settle_reply!("here is the answer")

    Conversations::Compaction::Request.call(
      Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @human
      )
    )
    handed = summary_loop.agent_run_tasks.sole.content_bodies.find_by!(role: "input").effective_text

    assert_includes handed, "User:\nwhat now\n\nAssistant:\nMock: here is the answer",
      "a kernel summary that never saw the question is the same defect one level up"
  end

  # THE ELISION SAYS SO, and it cuts at the round boundary. Byte-slicing
  # in silence handed the summarizer a history beginning mid-sentence
  # with no marker — so it summarized over the gap, confidently, and the
  # gap stayed invisible for the rest of the session.
  test "an overlong history drops whole rounds and names how many" do
    rounds = ["## Round a\n#{"a" * 300.kilobytes}",
              "## Round b\n#{"b" * 300.kilobytes}",
              "## Round c\ntail"]

    fitted = Conversations::Compaction::Serialize.fit(rounds)

    assert fitted.start_with?("[... 1 earlier round(s) elided to fit ...]"),
      "the count is only honest because the cut is on a round boundary"
    refute_includes fitted, "## Round a"
    assert_includes fitted, "## Round b", "the newest rounds are what survive"
    assert_includes fitted, "## Round c"
  end

  test "a history that fits carries no marker at all" do
    rounds = ["## Round a\nshort", "## Round b\nalso short"]
    fitted = Conversations::Compaction::Serialize.fit(rounds)
    assert_equal "## Round a\nshort\n\n## Round b\nalso short", fitted
  end

  # The byte clamp survives underneath the round cut for the one case
  # rounds cannot fix — a single round past the budget on its own — and
  # it announces itself too. The marker is inside the room, not added to
  # it: a rendering clamped to fit a `tool_input` that then grew by the
  # width of its own marker would fail the bound it was clamped for.
  test "the byte clamp under the round cut announces itself and still fits" do
    older, tail = Conversations::Compaction::Serialize.clamp_pair(
      "o" * 600_000, "t" * 40_000, :envelope_bound
    )

    assert_match(/\A\[\.\.\. \d+ earlier bytes elided to fit \.\.\.\]/, older)
    assert older.end_with?("o"), "the clamp still drops the OLDEST material"
    assert Nexus::SizeBounds.json_within?(
      :envelope_bound, { "history" => older, "retained_tail" => tail }
    ), "the marker is part of the room, not an addition to it"
  end

  # THE CLAMP MEASURES WHAT THE WALL MEASURES. `bounded_json` counts
  # `JSON.generate` bytes, and the address rides the same tool_input, so
  # a budget in RAW bytes minus a fixed headroom is a budget in the wrong
  # unit: escaping is content-dependent — under 2% on prose, 5.4% on the
  # tool pointers a coding round writes — and the delegated arm died on
  # precisely the transcripts it exists to repair.
  test "the clamp fits the ENCODED envelope, its escapes and its address included" do
    address = { "conversation" => "cnv_01JABCDEFGHJKMNPQRSTVWXYZ",
                "turn" => "trn_01JABCDEFGHJKMNPQRSTVWXYZ", "task" => "r12" }
    transcript = escaping_transcript(600_000)
    tail_text = escaping_transcript(4_000)

    older, tail = Conversations::Compaction::Serialize.clamp_pair(
      transcript, tail_text, :envelope_bound, address
    )

    assert older.present?, "the clamp keeps material; it does not empty the step"
    assert_equal tail_text, tail, "the tail still fits whole, so it does not yield"
    assert Nexus::SizeBounds.json_within?(
      :envelope_bound, address.merge("history" => older, "retained_tail" => tail)
    ), "the wall counts encoded bytes, so the clamp must count them too"
    refute Nexus::SizeBounds.json_within?(
      :envelope_bound, address.merge("history" => transcript.byteslice(0, 59_488), "retained_tail" => tail_text)
    ), "the raw-byte budget this replaces would not have fit"
  end

  # THE RE-CLAMP SPENDS THE ROOM IT MEASURED. A tail that fits the envelope whole, encoded and
  # beside its address, is the part the summarizer keeps specific, so it stays whole; the history
  # takes the room that is left, up to the bound — not a fraction of it.
  test "the clamp keeps a tail that fits whole and fills the room left beside it" do
    address = { "conversation" => "cnv_01JABCDEFGHJKMNPQRSTVWXYZ",
                "turn" => "trn_01JABCDEFGHJKMNPQRSTVWXYZ", "task" => "r12" }
    tail_text = escaping_transcript(55_000)
    limit = Nexus::SizeBounds.fetch(:envelope_bound)
    assert_operator Nexus::SizeBounds.json_bytesize(address.merge("history" => "", "retained_tail" => tail_text)), :<, limit,
      "the fixture's tail fits whole, so nothing obliges it to yield"

    older, tail = Conversations::Compaction::Serialize.clamp_pair(
      escaping_transcript(600_000), tail_text, :envelope_bound, address
    )

    assert_equal tail_text, tail, "the tail yields only after the history is gone"
    assert older.present?, "the room beside the tail carries history"
    encoded = Nexus::SizeBounds.json_bytesize(address.merge("history" => older, "retained_tail" => tail))
    assert_operator encoded, :<=, limit
    assert_operator encoded, :>, limit - 1.kilobyte, "the room the measurement found is spent, not thrown away"
  end
end
