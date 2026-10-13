require "test_helper"
require_relative "../../test_helpers/awaits_test_helper"

class AgentRuns::AwaitResultsTest < ActiveJob::TestCase
  include AwaitsTestHelper

  test "an oversized answer leaves the park standing" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "x" * (Nexus::SizeBounds::BOUNDS
        .fetch(AgentRuns::Parks::Settle::RESULT_BOUND).fetch(:value) + 1)
    )
    assert_equal :result_too_large, result.outcome
    assert_equal "dispatched", gate.reload.status, "the lease survives; the caller retries bounded"
  end

  # THE BOUNDARY USED TO FAIL OPEN. `content` was stored verbatim as
  # `{"text" => content}` while the size guard measured `content.to_s`, so
  # a submitted Array was sized as one thing and stored as another — and
  # `readable_text`'s `Array#join` then flattened it into a Ruby inspect
  # string that became the model's tool result. No 500, no 422, no log
  # line: the transcript was simply wrong.
  test "a result outside the grammar is refused, not silently flattened" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    {
      { "text" => "hi" } => :invalid_content,
      42 => :invalid_content,
      [{ "text" => "no type" }] => :invalid_content,
      [{ "type" => "text", "text" => 9 }] => :invalid_content,
      ["bare string"] => :invalid_content,
      # A WELL-FORMED BLOCK OF A KIND WE DO NOT CARRY YET gets its own
      # refusal, deliberately: "you sent a shape nobody takes" and "you
      # sent a kind we do not take yet" are different facts, and the
      # second becomes obsolete the round image lands.
      [{ "type" => "image", "upload_public_id" => "x" }] => :unsupported_content_kind,
    }.each do |shape, expected|
      result = AgentRuns::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: shape
      )
      assert_equal expected, result.outcome, "for #{shape.inspect}"
      assert_equal "dispatched", gate.reload.status, "the lease survives a malformed submission"
      assert_nil gate.content_bodies.find_by(role: "output"),
        "and nothing was written — the old path stored the flattened inspect form"
    end
  end

  # THE IDENTITY CASE IS LOAD-BEARING, not politeness. The
  # `function_call_output` entry IS the prompt-cache breakpoint, so a
  # text-only result whose stored bytes moved would bust the cached prefix
  # of every live loop at the marked position. A bare String and a
  # one-text-block array must write the SAME entry.
  test "a string and a single text block write byte-identical entries" do
    agent_run = seed(parallel(await("a"), await("b")), model("after"))
    start!(agent_run)

    plain = node(agent_run, "a")
    AgentRuns::Parks::Settle.call(
      node: plain, claim_token: plain.resolution_token, content: "the answer"
    )
    blocked = node(agent_run, "b")
    AgentRuns::Parks::Settle.call(
      node: blocked, claim_token: blocked.resolution_token,
      content: [{ "type" => "text", "text" => "the answer" }]
    )

    payloads = [plain, blocked].map do |task|
      task.content_bodies.find_by!(role: "output")
        .content_body_entries.includes(:content_fragment)
        .order(:position).map { |entry| entry.content_fragment.payload }
    end
    assert_equal [{ "text" => "the answer" }], payloads.first
    assert_equal payloads.first, payloads.last,
      "a runner adopting the block spelling must not move one cached byte"
  end

  # THE WHITESPACE DOOR, and it is the cache invariant's real test. The
  # engine's gate has always been `blank?`, so a whitespace-only result
  # writes NO body. Writing one instead is not a cosmetic difference:
  # `effective_text` is `readable_text.presence || canonical_entry_text`,
  # and a blank projection has no `presence` — so the model would be
  # handed `{"text":"\n"}`, the storage envelope's own JSON, exactly the
  # failure this grammar claims to remove. And that entry is the one the
  # prompt-cache breakpoint is stamped on.
  test "a blank result writes no body, whatever whitespace it is made of" do
    agent_run = seed(parallel(await("a"), await("b"), await("c")), model("after"))
    start!(agent_run)

    { "a" => "", "b" => "\n", "c" => "  \t\n " }.each do |key, blank|
      task = node(agent_run, key)
      result = AgentRuns::Parks::Settle.call(
        node: task, claim_token: task.resolution_token, content: blank
      )
      assert_predicate result, :applied?
      assert_nil task.reload.content_bodies.find_by(role: "output"),
        "#{blank.inspect} must write nothing — the model reads \"\" and not a JSON envelope"
    end
  end

  # And with structure beside it (the three channels): a blank text leaves the blocks empty and the
  # structure is STORED, not serialized into the text position — `content` is the model's,
  # `structured_content` the UI's. The model reads `""` in the sealed request, never the value and
  # never the storage envelope; the task read serves the structure whole.
  test "a blank text with structure hands the model nothing and the task read the structure" do
    call, output = paired_output_after(content: "\n", structured_content: { "ok" => true })

    assert_equal "", output, "the pairing's function_call_output is the writer's empty word"
    detail = AgentAPI::AgentRunPresenter.task_detail(call)
    assert_equal "", detail.fetch(:output)
    assert_equal({ "ok" => true }, detail.fetch(:structured_content))
    assert_not detail.key?(:content), "no text block was sent, so none is served"
  end

  # A FALSY STRUCTURED RESULT IS STILL A RESULT. A policy tool whose whole
  # answer is `false` had it written to the body and then served back as
  # absent — indistinguishable from a tool that sent none.
  test "a structured result of false survives the round trip" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "denied", structured_content: false
    )

    detail = AgentAPI::AgentRunPresenter.task_detail(gate.reload)
    assert_equal false, detail.fetch(:structured_content),
      "found by KEY, never by truthiness"
    assert_equal "denied", detail.fetch(:output)
  end

  # A BOUND THE GRAMMAR OWNS, so the refusal is a 422 the runner can act
  # on. Without it the storage count check fired instead and the runner
  # got a 409 — "try again later" about a payload that will never be
  # accepted.
  test "more blocks than the body can hold refuses in the grammar" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    ceiling = Nexus::SizeBounds::BOUNDS
      .fetch(AgentRuns::Parks::ResultContent::MAX_BLOCKS).fetch(:value)
    blocks = ->(n) { Array.new(n) { { "type" => "text", "text" => "x" } } }

    refused = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: blocks.call(ceiling + 1)
    )
    assert_equal :too_many_content_blocks, refused.outcome
    assert_equal "dispatched", gate.reload.status

    applied = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: blocks.call(ceiling)
    )
    assert_predicate applied, :applied?, "the ceiling itself must be storable"
  end

  # SIZING MUST NEVER RAISE, and depth is the case that proved the rescue
  # was too narrow: a structure nested past what can be stored raised a
  # raw JSON::NestingError out of a method whose whole contract is a typed
  # answer, which is a 500 with a backtrace instead of a refusal.
  test "a structure nested past storage refuses instead of raising" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    deep = (1..120).reduce("x") { |inner, _| [inner] }
    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, structured_content: deep
    )
    assert_equal :result_unstorable, result.outcome,
      "a typed refusal, not a JSON::NestingError escaping the sizing guard"
    assert_equal "dispatched", gate.reload.status, "the lease survives"
  end

  test "structured content rides beside the text, and never inside it" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "22.5 degrees", structured_content: { "temperature" => 22.5 }
    )

    body = gate.reload.content_bodies.find_by!(role: "output")
    payloads = body.content_body_entries.includes(:content_fragment)
      .order(:position).map { |entry| entry.content_fragment.payload }
    assert_equal [{ "text" => "22.5 degrees" }, { "structured" => { "temperature" => 22.5 } }],
      payloads
    assert_equal "22.5 degrees", body.effective_text,
      "the model reads the text projection; the structured entry is not text"
  end

  # MCP's SHOULD ("a tool that returns structured content SHOULD also return the serialized JSON in
  # a TextContent block") is the RUNNER's to honour, never the kernel's to enforce: structure with
  # no text writes the structured entry ALONE, and the writer's word — `readable_text: ""` — is what
  # keeps `effective_text` from falling back to the canonical entry JSON. The model is handed `""`,
  # not a JSON blob describing its own result, and not the value either.
  test "structured content with no text never reaches the model" do
    call, output = paired_output_after(structured_content: { "ok" => true })

    assert_equal "", output
    body = call.content_bodies.find_by!(role: "output")
    payloads = body.content_body_entries.includes(:content_fragment)
      .order(:position).map { |entry| entry.content_fragment.payload }
    assert_equal [{ "structured" => { "ok" => true } }], payloads, "no serialized text entry beside it"
    assert_equal "", body.readable_text, "the writer's word, stored"
    assert_equal "", body.effective_text
    refute_includes body.effective_text, "structured", "never the storage envelope"
    assert_equal 0, body.byte_size, "the stored size is the bytes effective_text answers (K-2c)"
  end

  test "a result type we cannot honour refuses rather than reading as complete" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    refused = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token,
      content: "hi", result_type: "input_required"
    )
    assert_equal :invalid_result_type, refused.outcome,
      "MRTR is not implemented; accepting its result type would be a lie"

    # Omitting result_type has the same completion behavior as explicitly passing "complete".
    %w[complete].each do |declared|
      applied = AgentRuns::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token,
        content: "hi", result_type: declared
      )
      assert_predicate applied, :applied?
    end
  end

  # `String.try_convert` is a CONVERSION, not a type check: an object that
  # answers `to_str` IS a string by Ruby's own protocol, and refusing it
  # would be this boundary substituting a type probe for a contract.
  test "a result that converts to text is text" do
    agent_run = seed(await("gate"))
    start!(agent_run)
    gate = node(agent_run, "gate")

    stringish = Class.new { def to_str = "converted" }.new
    result = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: stringish
    )
    assert_predicate result, :applied?
    assert_equal "converted",
      gate.reload.content_bodies.find_by!(role: "output").effective_text
  end

  test "the append envelope resolves atomically, and a failed outcome is refused there" do
    agent_run = seed(await("gate"))
    start!(agent_run)

    refused = grow(agent_run, model("late"), resolves: [{ "task" => "gate", "outcome" => "failed" }])
    assert_equal :unsupported_resolve_outcome, refused.outcome
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "late"),
      "one bad entry takes the WHOLE envelope back"
    assert_equal "dispatched", node(agent_run, "gate").status

    applied = grow(agent_run, model("next"), resolves: [{ "task" => "gate", "content" => "from the envelope" }])
    assert_predicate applied, :applied?
    assert_equal "completed", node(agent_run, "gate").status
    assert_equal "from the envelope",
      node(agent_run, "gate").content_bodies.find_by!(role: "output").effective_text
    assert_equal "queued", node(agent_run, "next").status,
      "the task authored in the same envelope depends on the await it resolved"
  end

  test "an unknown await in the envelope refuses without appending" do
    agent_run = seed(model("only"))
    start!(agent_run)

    result = grow(agent_run, ask("extra"), resolves: ["nope"])
    assert_equal :unknown_await, result.outcome
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "extra")
  end
end
