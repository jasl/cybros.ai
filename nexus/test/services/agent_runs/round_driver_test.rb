require "test_helper"
require_relative "../../test_helpers/agent_runs_round_driver_test_helper"

# The kernel round driver. A model step that answered with tool calls is the MIDDLE of a turn: the
# kernel expands it inside the converger's own transaction into one tool task per call plus one
# continuation that splices the round and waits on the whole fan.
class AgentRuns::RoundDriverTest < ActiveJob::TestCase
  include AgentRunsRoundDriverTestHelper

  test "a round with calls expands into a fan and a continuation, without ticking the revision" do
    agent_run = seed(model("ask", "prompt" => "read them"))
    start!(agent_run)
    revision_before = agent_run.reload.revision

    run_step!(agent_run, sse_success("calling", tool_calls: calls("a", "b")), key: "ask")

    fan = %w[r1t0 r1t1].map { |key| node(agent_run, key) }
    assert_equal %w[read_file read_file], fan.map(&:tool_name)
    assert_equal %w[call_0 call_1], fan.map(&:tool_call_id),
      "each fan member carries the provider's own pairing key"
    assert_equal [{ "path" => "a" }, { "path" => "b" }], fan.map(&:tool_input)
    assert_equal %w[absorb absorb], fan.map(&:on_failure),
      "kernel fans absorb: a tool that could not run must still reach the model"
    assert_equal [%w[ask], %w[ask]], fan.map { |n|
      n.incoming_edges.map { |e| e.from_node.node_key }
    }

    continuation = node(agent_run, "r1")
    assert_equal "round", continuation.continuation_source,
      "the main-thread marker - the mainline is structural, never inferred from keys"
    assert_equal %w[r1t0 r1t1],
      continuation.incoming_edges.map { |e| e.from_node.node_key }.sort
    assert_equal %w[ask r1t0 r1t1], continuation.input_from_node_keys,
      "it splices the round it came from AND the whole fan"
    assert_equal fixture_runner_declarations([READ_TOOL]), continuation.tool_definitions,
      "the complete request surface is inherited - a continuation that could " \
        "not carry the tools would strand the loop on its first call"
    assert_equal "dev", continuation.provider_id

    assert_equal revision_before, agent_run.reload.revision,
      "the counter coordinates WRITERS; the execution trace never ticks it"
    assert_equal continuation.id, agent_run.deliverable_node_id,
      "the answer moves to the continuation - the loop must not complete on " \
        "a round that only asked for tools"
  end

  # The declaration is the ONLY gate:
  # a kernel tool the round never declared is refused exactly as a runner's
  # would be — "off" means absent from the bytes AND refused if guessed —
  # and the round goes on, because one bad name never fails a round.
  test "a kernel tool the round never declared fails at birth like any other" do
    agent_run = seed(model("ask", "prompt" => "read them"))
    start!(agent_run)

    run_step!(agent_run, sse_success("guessing", tool_calls: [
      { id: "call_0", name: "wait", arguments: '{"tasks":["future"]}' },
      { id: "call_1", name: "read_file", arguments: '{"path":"a"}' },
    ]), key: "ask")

    guessed = node(agent_run, "r1t0")
    assert_equal %w[failed unknown_tool], [guessed.status, guessed.error_key],
      "the kernel runs wait, but this round never offered it"
    assert_equal "dispatched", node(agent_run, "r1t1").status, "the declared one parks on its runner"
    assert_equal "queued", node(agent_run, "r1").status, "the loop continues"
  end

  # THE ONE RESOLUTION SITE: a call made under an alias becomes a row under the kernel's wire name,
  # its input mapped, the model's spelling kept beside it — so every reader downstream sees `task`.
  test "a call made as Agent runs the kernel's task, its parameters mapped and inverted" do
    agent_run = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, RunLaneTestHelper::AGENT_ALIAS]))
    start!(agent_run)
    assert_equal %w[Agent read_file], node(agent_run, "ask").tool_definitions.map { |e| e.dig("function", "name") }
    assert_equal true, node(agent_run, "ask").tool_definitions.first.dig("function", "parameters", "properties",
      "run_in_background", "default"), "the round's tools are the render"

    run_step!(agent_run, sse_success("delegating", tool_calls: [
      { id: "call_0", name: "Agent", arguments: { prompt: "review", run_in_background: false }.to_json },
      { id: "call_1", name: "Agent", arguments: { prompt: "later" }.to_json },
    ]), key: "ask")

    waited, detached = %w[r1t0 r1t1].map { |key| node(agent_run, key) }
    assert_equal ["delegate_task", "Agent", { "prompt" => "review", "wait" => true }],
      [waited.tool_name, waited.tool_alias, waited.tool_input]
    assert_equal ["delegate_task", "Agent", { "prompt" => "later" }],
      [detached.tool_name, detached.tool_alias, detached.tool_input], "absent stays absent: the kernel's default"
    assert_equal "queued", node(agent_run, "r1").status
  end

  test "an omitted parameter never reaches the kernel: spawn_agent with wait is detached anyway" do
    spawn = { "name" => "spawn_agent", "canonical" => "nexus.graph.delegate_task", "omit" => ["wait"] }
    agent_run = seed(model("ask", "prompt" => "delegate", "tools" => [READ_TOOL, spawn]))
    start!(agent_run)

    run_step!(agent_run, sse_success("delegating", tool_calls: [
      { id: "call_0", name: "spawn_agent", arguments: { prompt: "go", wait: true }.to_json },
    ]), key: "ask")

    call = node(agent_run, "r1t0")
    assert_equal ["delegate_task", "spawn_agent", { "prompt" => "go" }], [call.tool_name, call.tool_alias, call.tool_input]
  end

  test "the whole loop runs: the runner answers the fan and the continuation reads it" do
    agent_run = seed(model("ask", "prompt" => "read it"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a", "b")), key: "ask")

    fan = %w[r1t0 r1t1].map { |key| node(agent_run, key) }
    assert_equal %w[dispatched dispatched], fan.map(&:status),
      "the fan PARKS on its runner - the kernel handed the work out"
    assert_equal "queued", node(agent_run, "r1").status,
      "and the continuation waits for the whole fan"

    assert_predicate submit!(agent_run, "r1t0", content: "contents of a"), :applied?
    assert_equal "queued", node(agent_run, "r1").status, "one answer is not the fan"
    assert_predicate submit!(agent_run, "r1t1", content: "denied",
      is_error: true), :applied?
    schedule!(agent_run)

    errored = node(agent_run, "r1t1")
    assert_equal "completed", errored.status,
      "a tool that RAN and errored is COMPLETED - is_error is data, not control"
    assert errored.output_summary.fetch("is_error")

    results = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .select { |p| p["type"] == "tool_result_item" }
      .map { |p| p.fetch("payload") }
    assert_equal ["contents of a",
                  "#{AgentRuns::RoundReplay::Pairing::ERROR_OPEN}denied" \
                    "#{AgentRuns::RoundReplay::Pairing::ERROR_CLOSE}"],
      results.map { |p| p["output"] }, "both answers ride in CALL order, and the error is MARKED"
    # The FIELD beside the marker (alignment audit F7): the errored
    # result carries `is_error: true`, the clean one no key at all — the
    # Anthropic wire lowers it to `tool_result.is_error`; the fixed-key
    # Responses and Gemini builders drop it.
    assert_equal [false, true], results.map { |p| p.key?("is_error") }
    assert results.last.fetch("is_error")

    run_step!(agent_run, sse_success("done then"), key: "r1")
    assert_equal "completed", agent_run.reload.status,
      "a round with no calls is the turn's terminal"
  end

  test "rounds chain: each continuation can expand again, and keys never collide" do
    agent_run = seed(model("ask"), model("r1"))
    start!(agent_run)
    run_step!(agent_run, sse_success("one", tool_calls: calls("a")), key: "ask")

    assert_equal %w[ask r2t0], node(agent_run, "r2").input_from_node_keys,
      "the driver bumps past a key a client already authored"
    assert_equal %w[ask r2], node(agent_run, "r1").sources.map(&:node_key).sort,
      "the authored round after the expanding round is handed to its frontier"
    assert_equal ["r2"], node(agent_run, "r1").input_from_node_keys, "and replays history through it"

    submit!(agent_run, "r2t0", content: "a")
    schedule!(agent_run)
    run_step!(agent_run, sse_success("two", tool_calls: calls("b")), key: "r2")
    assert_equal %w[r1 r2 r3], agent_run.agent_run_tasks
      .where("node_key ~ '^r[0-9]+$'").order(:id).map(&:node_key),
      "the mainline grows one continuation per round"
    assert_equal "r3t0", node(agent_run, "r3").incoming_edges.sole.from_node.node_key
    assert_equal ["r3"], node(agent_run, "r1").input_from_node_keys, "forwarded twice"
  end

  test "an unparseable arguments string is authored, failed with its reason, and never waited on" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "call_bad", name: "read_file", arguments: "{not json" },
    ]), key: "ask")

    fan = node(agent_run, "r1t0")
    assert_equal "failed", fan.status
    assert_equal "invalid_tool_arguments", fan.error_key,
      "the pairing law owes every call a task; an unrunnable one fails at once"
    assert_equal "running", node(agent_run, "r1").status
  end

  # The Anthropic stream cut by max_tokens hands the kernel the partial text it accumulated. Nothing
  # may run on it: the call is refused, and the refusal is the tool result the continuation reads.
  test "a truncated call is refused as data the model reads, never run with empty arguments" do
    partial = %({"path":"/tmp/fo)
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "call_cut", name: "read_file", arguments: partial },
    ]), key: "ask")

    fan = node(agent_run, "r1t0")
    assert_equal "failed", fan.status
    assert_equal "invalid_tool_arguments", fan.error_key
    assert_nil fan.claim_token, "the task never reached a runner"

    outputs = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .select { |p| p["type"] == "tool_result_item" }
      .map { |p| p["payload"] }
    assert_equal ["call_cut"], outputs.map { |p| p["call_id"] }
    assert_includes outputs.sole["output"], "invalid_tool_arguments"
    assert outputs.sole["output"].start_with?(AgentRuns::RoundReplay::Pairing::ERROR_OPEN),
      "the refusal is MARKED so the model reads it as an error, not an answer"
  end

  # An output cut short by the token budget: when the round's own finish says the output budget cut
  # it, the cut call is failed under a key that names the cut and a sentence the model reads — WHY,
  # not just "bad JSON" — while a complete sibling in the same batch still runs.
  test "a call cut by the output budget is failed as truncated_tool_arguments and the model reads the cut" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_incomplete("calling", tool_calls: [
      { id: "call_cut", name: "read_file", arguments: %({"path":"/tmp/fo) },
      { id: "call_whole", name: "read_file", arguments: %({"path":"/tmp/whole"}) },
    ]), key: "ask")

    assert_equal "output_budget_exhausted",
      ModelInvocation.find(node(agent_run, "ask").selected_model_invocation_id).finish_quality
    cut = node(agent_run, "r1t0")
    assert_equal "failed", cut.status
    assert_equal "truncated_tool_arguments", cut.error_key, "the key names the cut, not the JSON"
    assert_includes cut.error_detail, "output token limit"
    whole = node(agent_run, "r1t1")
    assert_includes %w[queued dispatched], whole.status, "the batch is never refused: the whole call runs"

    assert_predicate submit!(agent_run, "r1t1", content: "the whole file"), :applied?
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "r1").status
    outputs = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .select { |p| p["type"] == "tool_result_item" }
      .map { |p| p["payload"] }
    envelope = outputs.find { |p| p["call_id"] == "call_cut" }.fetch("output")
    assert envelope.start_with?(AgentRuns::RoundReplay::Pairing::ERROR_OPEN)
    assert_includes envelope, "truncated_tool_arguments"
    assert_includes envelope, "output token limit", "the model reads WHY in the envelope"
    assert_equal "the whole file", outputs.find { |p| p["call_id"] == "call_whole" }.fetch("output")
  end

  # ONE CALL OVER THE TOOL-INPUT BOUND WEDGED THE ROUND. A single call whose arguments exceed the
  # 64 KiB a tool_input may carry passed the batch's 1 MB check, then raised `RecordInvalid` at the
  # row's `create!` inside the converger's transaction. The converger rescued and rolled back, so the
  # same invocation was picked up and raised again on every wake: the round stayed `running` forever
  # and the model never heard why. A coding model writing one ~100 KB file reaches it. The call is now
  # authored with nothing of what it could not store, failed under a key that names the size, and the
  # model reads the sentence — while a sibling in the same batch still runs.
  test "a call over the tool-input bound is failed as tool_input_too_large and never wedges the round" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    big = { "path" => "/tmp/big", "content" => "x" * 70_000 }.to_json
    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "call_big", name: "read_file", arguments: big },
      { id: "call_small", name: "read_file", arguments: %({"path":"/tmp/small"}) },
    ]), key: "ask")

    invocation = ModelInvocation.find(node(agent_run, "ask").selected_model_invocation_id)
    refute_nil invocation.terminal_event_recorded_at, "the round is applied once, never retried on every wake"
    oversized = node(agent_run, "r1t0")
    assert_equal "failed", oversized.status
    assert_equal "tool_input_too_large", oversized.error_key, "the key names the size, not the JSON"
    assert_includes oversized.error_detail, "65,536", "the model reads the bound it crossed"
    assert_includes oversized.error_detail, "70,0", "and the size it sent"
    assert_equal({}, oversized.tool_input, "the row carries none of the arguments it could not store")
    assert_nil oversized.claim_token, "the task never reached a runner"
    small = node(agent_run, "r1t1")
    assert_includes %w[queued dispatched], small.status, "the batch is never refused: the small call runs"

    # What the continuation's model reads for this call, through the one renderer every round's
    # results pass (read here directly: replaying the model's own oversized arguments in the
    # continuation's history arms compaction on the mock's small window, which is the kernel
    # working as designed and not what this pins).
    envelope = AgentRuns::RoundReplay::Pairing.output_for(oversized)
    assert envelope.start_with?(AgentRuns::RoundReplay::Pairing::ERROR_OPEN), "marked as an error, not an answer"
    assert_includes envelope, "(tool_input_too_large)"
    assert_includes envelope, "over the 65,536 bytes one tool call may carry", "the model reads WHY"
    assert_equal 1, envelope.scan("could not run").size, "the reason is said once, not twice"
  end

  # A CALL WHOSE ARGUMENTS THE ROW CANNOT STORE REFUSED THE WHOLE ROUND. JSON spells U+0000 as
  # `\u0000` and a model emits it (a nested template literal's backtick came back as one); PostgreSQL
  # text cannot hold it, so the compiler's `invalid_tool_input` refused the round's whole envelope and
  # the loop halted on `round_expansion_refused` — the model never read why. Like an oversized input,
  # the call is authored with none of its arguments and failed with the encoder's own sentence, its
  # sibling runs, and the loop continues.
  test "a call whose arguments carry U+0000 is failed as invalid_tool_input and the round goes on" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "call_nul", name: "read_file", arguments: %({"path":"/tmp/a\\u0000b"}) },
      { id: "call_ok", name: "read_file", arguments: %({"path":"/tmp/ok"}) },
    ]), key: "ask")

    assert_equal "completed", node(agent_run, "ask").status, "the round is expanded, never refused"
    unstorable = node(agent_run, "r1t0")
    assert_equal %w[failed invalid_tool_input], [unstorable.status, unstorable.error_key]
    assert_equal({}, unstorable.tool_input, "the row carries none of the arguments it could not store")
    assert_nil unstorable.claim_token, "the task never reached a runner"
    ordinary = node(agent_run, "r1t1")
    assert_includes %w[queued dispatched], ordinary.status, "the sibling runs"
    assert_equal({ "path" => "/tmp/ok" }, ordinary.tool_input, "an ordinary call is unchanged")

    envelope = AgentRuns::RoundReplay::Pairing.output_for(unstorable)
    assert envelope.start_with?(AgentRuns::RoundReplay::Pairing::ERROR_OPEN), "marked as an error, not an answer"
    assert_includes envelope, "(invalid_tool_input)"
    assert_includes envelope, "A string carrying U+0000 cannot be stored: remove it before submitting.",
      "the model reads the encoder's own sentence"

    assert_predicate submit!(agent_run, "r1t1", content: "ok"), :applied?
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "r1").status, "the loop continues on the failure"
  end

  # A provider's call id is stored on the call's row, whose column holds 128 characters. An id past
  # it, or a repeated one the disambiguation pushes past it, must still become a row: a row that
  # cannot be stored raises inside the converger, which rolls back and meets the same invocation on
  # every wake. The replayed call and its result carry the same bounded key, so they still pair.
  test "an over-long provider call id is replaced by a bounded key and never wedges the round" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: [
      { id: "c" * 200, name: "read_file", arguments: %({"path":"/tmp/a"}) },
      { id: "d" * 125, name: "read_file", arguments: %({"path":"/tmp/b"}) },
      { id: "d" * 125, name: "read_file", arguments: %({"path":"/tmp/c"}) },
    ]), key: "ask")

    invocation = ModelInvocation.find(node(agent_run, "ask").selected_model_invocation_id)
    refute_nil invocation.terminal_event_recorded_at, "the round is applied once, never retried on every wake"
    fan = %w[r1t0 r1t1 r1t2].map { |key| node(agent_run, key) }
    ids = fan.map(&:tool_call_id)
    assert_equal 3, ids.uniq.size
    assert ids.all? { |id| id.length <= Nexus::ModelToolCalls::MAX_ID_LENGTH }, ids.inspect
    assert_equal "queued", node(agent_run, "r1").status, "the continuation is authored"

    fan.each { |call| submit!(agent_run, call.node_key, content: "read #{call.tool_input["path"]}") }
    schedule!(agent_run)
    entries = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
    replayed = entries.select { |p| p["type"] == "tool_call_item" }.map { |p| p.dig("payload", "call_id") }
    results = entries.select { |p| p["type"] == "tool_result_item" }.map { |p| p["payload"] }
    assert_equal ids, replayed, "the replayed calls carry the keys their rows store"
    assert_equal ids, results.map { |p| p["call_id"] }, "and each result pairs with its call"
    assert_equal ["read /tmp/a", "read /tmp/b", "read /tmp/c"], results.map { |p| p["output"] }
  end

  # A name the model invented that no row can hold — past the column's 128 characters — is still an
  # undeclared name: it fails as `unknown_tool` on its own, and its sibling runs. Refusing the batch
  # would turn one bad name among N good calls into a failed round.
  test "an over-long undeclared tool name fails that call as unknown_tool, never the round" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("guessing", tool_calls: [
      { id: "call_0", name: "x" * 200, arguments: %({"path":"/tmp/a"}) },
      { id: "call_1", name: "read_file", arguments: %({"path":"/tmp/b"}) },
    ]), key: "ask")

    invented = node(agent_run, "r1t0")
    assert_equal %w[failed unknown_tool], [invented.status, invented.error_key]
    assert_equal AgentRuns::ExpandRound::UNKNOWN_TOOL, invented.tool_name,
      "the row is named by the failure it is given, which is also what the repeat brake compares"
    assert_nil invented.claim_token, "the task never reached a runner"
    assert_equal "dispatched", node(agent_run, "r1t1").status, "the declared one parks on its runner"
    assert_equal "queued", node(agent_run, "r1").status, "the loop continues"
  end

  # an outcome that cannot be stored is a FAILED outcome, not an open park to its claim deadline.
  # The runner's report is refused (the door still answers 422 — these bytes can never be stored),
  # but the park is closed: the node fails `result_unstorable` naming the refusal, and the
  # continuation reads the failure in the next round instead of waiting for the sweep.
  test "an unstorable tool result fails the node at once, and the next round reads why" do
    agent_run = seed(model("ask", "prompt" => "read it"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a")), key: "ask")

    refused = submit!(agent_run, "r1t0", content: "bytes with a NUL \u0000 inside")
    assert_equal :result_unstorable, refused.outcome, "the runner's report was refused"
    assert_not_predicate refused, :applied?

    fan = node(agent_run, "r1t0")
    assert_equal %w[failed result_unstorable], [fan.status, fan.error_key]
    assert_includes fan.error_detail, "unsupported_text", "the detail names the refusal"

    assert_equal :idle, submit!(agent_run, "r1t0", content: "again").outcome, "the park is closed: a late answer is idle"

    schedule!(agent_run)
    continuation = node(agent_run, "r1")
    assert_equal "running", continuation.status, "absorb: the round continues on the failure"
    output = ModelInvocation.find(continuation.selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .find { |p| p["type"] == "tool_result_item" }.dig("payload", "output")
    assert_includes output, "(result_unstorable)"
    assert_includes output, "unsupported_text"
    assert_not_includes output, "could not run", "the tool RAN; the model must not retry it unchanged"
  end

  test "fan_on_failure: propagate makes a failed tool end the round" do
    agent_run = seed(model("ask", "fan_on_failure" => "propagate"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a")), key: "ask")

    assert_equal "propagate", node(agent_run, "r1t0").on_failure
    assert_predicate submit!(agent_run, "r1t0", content: "could not start",
      outcome: "failed"), :applied?
    schedule!(agent_run)
    assert_equal "skipped", node(agent_run, "r1").status,
      "the fail-fast option: the continuation is skipped with its fan"
    assert_equal "propagate", node(agent_run, "r1").fan_on_failure,
      "and the intent is inherited, so one authored choice governs the mainline"

    refused = AgentRuns::Tasks::Compile.call([ask("a", "fan_on_failure" => "absorb")],
      AgentRuns::Tasks::Tip.seed("round"))
    assert_equal "unknown_step_option", refused.errors.sole.fetch("code"),
      "the fan policy is a model step's fact; an ask has no fan"
  end

  test "the mainline sharpens the steer boundary and renders as the main thread" do
    agent_run = seed(model("ask"), detached(model("side", "prompt" => "background")))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a")), key: "ask")
    submit!(agent_run, "r1t0", content: "contents")

    # A steer arrives while the continuation is ready and the background branch is ready too. Before
    # the mainline existed that was ambiguous and the steer waited; the main thread answers the
    # question.
    assert_predicate loop_input!(agent_run, acting_user: @human, text: "focus on this"), :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)

    texts = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.filter_map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_includes texts, "focus on this",
      "the directive lands on the CONTINUATION - a background branch being " \
        "ready no longer makes `next` ambiguous"
    assert_equal 0, agent_run.steering_inputs.count

    assert_equal "round", node(agent_run, "r1").continuation_source,
      "the mainline is structural, never inferred from a key convention"
    assert_equal "branch", node(agent_run, "side").continuation_source,
      "a background step is a branch by position, never a second mainline"
  end

  test "a forced pause marks the abort, unless the user's own words follow" do
    agent_run = seed(model("ask", "prompt" => "go"))
    start!(agent_run)
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)

    texts = ModelInvocation.find(node(agent_run, "ask").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_equal [AgentRuns::InputComposition::ABORT_MARKER, "go"], texts,
      "an interrupted round must not look like a round that produced nothing"

    # Now the discriminated half: the SAME gesture carrying a directive
    # writes NO marker, because the user's own words explain it better.
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_predicate loop_input!(agent_run, acting_user: @human, text: "do this instead"), :accepted?
    AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)

    resumed = ModelInvocation.find(node(agent_run, "ask").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
    assert_equal ["go", "do this instead"], resumed,
      "the message follows, so the kernel says nothing of its own"
  end

  test "a graceful pause does not destroy the round that lands during it" do
    agent_run = seed(model("ask", "prompt" => "read it"))
    start!(agent_run)

    # The documented default arm: scheduling stops, the in-flight step
    # runs to its terminal and its result still applies.
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    apply_via(step_attempt(agent_run, "ask"),
      sse_success("calling", tool_calls: calls("a")))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs

    assert_equal "call_0", node(agent_run, "r1t0").tool_call_id,
      "the round expanded WHILE paused - gating expansion on `running` " \
        "silently destroyed the turn (slice review, critical)"
    assert_equal "queued", node(agent_run, "r1t0").status,
      "and nothing STARTS until resume, which is what pause means"

    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "dispatched", node(agent_run, "r1t0").status
  end

  test "a round too wide to author FAILS the step instead of vanishing" do
    agent_run = seed(model("ask"))
    start!(agent_run)

    over = AgentRuns::Tasks::Compile::KERNEL_MAX_DEPENDENCIES_PER_TASK + 1
    wide = (0...over).map do |n|
      { id: "call_#{n}", name: "read_file", arguments: "{}" }
    end
    run_step!(agent_run, sse_success("calling", tool_calls: wide), key: "ask")

    ask = node(agent_run, "ask")
    assert_equal "failed", ask.status
    assert_equal AgentRuns::ExpandRound::EXPANSION_REFUSED, ask.error_key,
      "a turn whose continuation cannot exist must not be reported as an " \
        "answer - it vanished silently before (slice review)"
    assert_equal 0, agent_run.agent_run_tasks.where.not(node_key: "ask").count
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    assert_equal "needs_attention", agent_run.reload.status,
      "and the halt policy asks the user rather than completing"
  end

  test "an ordinary wide fan the client could not author is fine for the kernel" do
    agent_run = seed(model("ask"))
    start!(agent_run)

    width = AgentRuns::Tasks::Compile::MAX_DEPENDENCIES_PER_TASK + 3
    run_step!(agent_run, sse_success("calling", tool_calls: (0...width).map do |n|
      { id: "call_#{n}", name: "read_file", arguments: "{}" }
    end), key: "ask")

    assert_equal width, agent_run.agent_run_tasks
      .where(type: "AgentRunTasks::ToolTask").count,
      "the client caps are request HYGIENE; a round driver transcribes what " \
        "a model emitted, and a 35-call read fan is ordinary output"
    assert_equal "queued", node(agent_run, "r1").status
  end

  test "a forced stop cancels parked tool tasks, so the drain can finish" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a", "b")), key: "ask")
    assert_equal %w[dispatched dispatched],
      %w[r1t0 r1t1].map { |k| node(agent_run, k).status }

    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    assert_equal %w[canceled canceled],
      %w[r1t0 r1t1].map { |k| node(agent_run, k).status },
      "stop means stop: a park nobody will answer cannot wedge the drain"
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    assert_equal "canceled", agent_run.reload.status
  end

  test "a forced pause DRAINS the fan rather than cancelling it — the round can resume" do
    # Cancellation semantics: a canceled fan member settles:skip by design, so cancelling one would
    # take the continuation with it. Cancellation is for a loop that is dying, never a round being
    # re-minted.
    agent_run = seed(model("ask"))
    start!(agent_run)
    run_step!(agent_run, sse_success("calling", tool_calls: calls("a", "b")), key: "ask")
    submit!(agent_run, "r1t0", content: "first answer")

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.new(
      agent_run: agent_run, acting_user: @human, force: true
    )), :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs

    assert_equal "dispatched", node(agent_run, "r1t1").status,
      "the surviving park is untouched: a forced pause aborts model steps, " \
        "not the work a runner is already holding"
    assert_equal "completed", node(agent_run, "r1t0").status,
      "and an answer that already landed keeps its real result"
    assert_equal [], Executors::Inbox.call(executor: suite_runner).tasks,
      "no NEW work is handed out while the clocks are frozen"

    # A runner that already holds the item can still answer it — its work
    # is in flight, and refusing here would strand the round.
    assert_predicate submit!(agent_run, "r1t1", content: "second answer"), :applied?

    assert_predicate AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    outputs = ModelInvocation.find(node(agent_run, "r1").selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload }
      .select { |p| p["type"] == "tool_result_item" }
      .map { |p| p.dig("payload", "output") }
    assert_equal ["first answer", "second answer"], outputs,
      "the round resumes whole - nothing was skipped and nothing synthesized"
  end

  test "no cumulative ceiling: a loop past hundreds of rounds still expands (Q2, 2026-09-05)" do
    agent_run = seed(model("ask"))
    start!(agent_run)
    # BORN QUEUED, THEN STAMPED: a round is only completed by running, so
    # the fixture takes the `update_columns` shortcut rather than asking
    # the machine for an edge the engine never performs.
    300.times do |n|
      node = agent_run.agent_run_tasks.create!(
        node_key: "spent#{n}", type: "AgentRunTasks::ModelTask",
        authored_by: "author",
        continuation_source: "round", provider_id: "dev", model_ref: "mock-text"
      )
      node.update_columns(status: "completed", completed_at: Time.current)
    end

    run_step!(agent_run, sse_success("calling", tool_calls: calls("a")), key: "ask")

    assert_equal "completed", node(agent_run, "ask").reload.status
    assert_equal 1, agent_run.agent_run_tasks.where(type: "AgentRunTasks::ToolTask").count,
      "long-horizon work is the norm — concurrency is the only capacity control"
  end

  # THE COUNT IS NOT A WALL (Gate 3, 2026-09-10). A long loop of small
  # rounds — read, append, read, append — crossed 256 request entries near
  # round 125 and died `content_items_too_many` with its bytes nowhere near
  # the byte wall: the entry-count bound was a cumulative ceiling under
  # another name, and no compaction could repair it, since prune keeps
  # every entry (a cleared result is a placeholder, never a removal). The
  # count is storage's sanity bound now, sized above what the byte wall
  # admits; bytes stay the one wall that arms. Each round here is one
  # call (call + result + answer = three entries), and the calls differ
  # so the repeat brake stays out of it. 130 rounds, not 300: the real
  # chain costs ~0.4 s a round through admit, converge and schedule, and
  # 390 entries are already half again past the old wall.
  MAINLINE_ROUNDS = 130

  test "a mainline of small rounds past 256 entries composes under the byte wall — never refused for its count, never armed" do
    agent_run = seed(model("ask"))
    start!(agent_run)

    key = "ask"
    MAINLINE_ROUNDS.times do |n|
      round = node(agent_run, key)
      assert_equal "running", round.status,
        "round #{n} (#{key}) was not scheduled: #{round.error_key.inspect} #{round.error_detail.inspect}"
      run_step!(agent_run, sse_success("r#{n}", tool_calls: calls("f#{n}")), key: key)
      submit!(agent_run, "r#{n + 1}t0", content: "x")
      schedule!(agent_run)
      key = "r#{n + 1}"
    end

    last = node(agent_run, key)
    assert_equal "running", last.status, "the newest continuation minted its request"
    entries = ModelInvocation.find(last.selected_model_invocation_id)
      .content_bodies.find_by!(role: "request").content_body_entries.count
    assert_operator entries, :>=, 3 * MAINLINE_ROUNDS, "the whole chain rode in the request"
    assert_operator entries, :>, 256, "past the count that was once a wall"

    rows = agent_run.agent_run_tasks.reload
    model_rows = rows.select { |row| row.is_a?(AgentRunTasks::ModelTask) }
    assert_equal ["completed"], (model_rows - [last]).map(&:status).uniq,
      "every earlier round ran to its answer"
    assert_empty rows.select { |row| row.error_key == Nexus::SizeBounds::COUNT_REJECTION.to_s },
      "no round was refused for its count"
    assert_empty model_rows.select(&:repaired?), "nothing armed: bytes are the only wall, and they were not hit"
  end

  test "kernel-only fields are refused on the public door" do
    { tool("x", "t", "tool_call_id" => "v") => "invalid_tool_call_id",
      tool("x", "t", "alias" => "Agent") => "unknown_step_option",
      tool("x", "t", "continue" => "round") => "unknown_step_option",
      model("x", "detach" => true) => "edge_authoring_refused" }.each do |step, code|
      refused = AgentRuns::Tasks::Compile.call([step], AgentRuns::Tasks::Tip.seed("round"))
      assert_equal [code], refused.errors.map { |e| e.fetch("code") },
        "a client must not forge the main thread or reach for another round's tool result"
    end
  end

  # The answer is the envelope's end, so a create names none; the designation is the only reader —
  # no last-sink fallback decides quiescence.
  test "a create with no steps is refused, and the envelope's end is the only node that completes a loop" do
    assert_equal :steps_required, create_loop.outcome
    assert_equal 0, AgentRun.count, "refused before any row"

    agent_run = seed(model("answer", "on_failure" => "absorb"), model("side"))
    assert_equal "side", agent_run.deliverable_node.node_key, "the answer is the end, by construction"
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }), key: "answer")
    assert_equal "running", agent_run.reload.status, "an absorbed failure holds nothing; the answer is still to come"
    run_step!(agent_run, sse_success("the side"), key: "side")

    agent_run.reload
    assert_equal "completed", node(agent_run, "side").status
    assert_equal "completed", agent_run.status

    agent_run.update!(deliverable_node_id: nil)
    assert_nil agent_run.deliverable, "nil is only the reaped state: no fallback to the last sink"
  end
end
