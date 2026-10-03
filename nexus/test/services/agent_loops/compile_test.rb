require "test_helper"

# The lowering as a table: (step × starting tip) → the edges, the reads, the
# mark, `detached` and the final tip — plus every refusal by its path.
# Written order is the whole grammar; nothing here names an edge.
class AgentLoops::CompileTest < ActiveSupport::TestCase
  Compile = AgentLoops::Tasks::Compile
  Known = AgentLoops::Tasks::Known
  Step = AgentLoops::Tasks::Step

  def compile(steps, tip = seed_tip, **options)
    Compile.call(steps, tip, **options)
  end

  def seed_tip = AgentLoops::Tasks::Tip.seed(Compile::ROUND)

  def at(key, kind = "model_task", mark = Compile::ROUND) = Known.new(key: key, kind: kind, mark: mark)

  # The boundary an authored envelope starts from: the completed spine
  # round `rN` as spine and sole wait, nothing unread behind it.
  def after_round(key = "rN")
    AgentLoops::Tasks::Tip.new(spine: at(key), waits: [at(key)], reads: [], mark: Compile::ROUND, detached: false)
  end

  def nodes(result) = result.nodes.index_by { |node| node["node_key"] }
  def edges(result) = result.edges.map { |edge| [edge["from_key"], edge["to_key"]] }
  def reads(result, key) = nodes(result).fetch(key)["input_from_node_keys"]
  def tip_keys(tip) = [tip.spine&.key, tip.waits.map(&:key), tip.reads.map(&:key)]

  test "a wait absorbs expiry by default, including an explicit null policy" do
    result = compile([
      { "wait" => { "key" => "ordinary", "task" => "existing" } },
      { "wait" => { "key" => "null", "task" => "existing", "on_failure" => nil } },
      { "wait" => { "key" => "strict", "task" => "existing", "on_failure" => "halt" } },
    ])
    assert_predicate result, :valid?, result.errors.inspect
    assert_equal %w[absorb absorb halt], result.nodes.map { |node| node.fetch("on_failure") }
  end

  test "wake inherits authoring context independently of lifetime and step overrides" do
    result = compile([
      model("explicit", "wake" => "passive", "lifetime" => "turn"), model("ordinary"),
      parallel(tool("grouped"), tool("active", "wake" => "auto"),
        wake: "passive", until: "any", key: "race"),
      model("after_group"),
    ])

    assert_predicate result, :valid?, result.errors.inspect
    assert_equal({ "explicit" => "passive", "ordinary" => "auto", "grouped" => "passive",
      "active" => "auto", "race" => "passive", "after_group" => "auto" },
      nodes(result).transform_values { |node| node.fetch("wake") })
    assert_equal "auto", result.tip.wake

    inherited = compile([model("active", "wake" => "auto"), model("inherited")], seed_tip.with(wake: "passive"))
    assert_predicate inherited, :valid?, inherited.errors.inspect
    assert_equal %w[auto passive], inherited.nodes.map { |node| node.fetch("wake") }
    assert_equal %w[conversation conversation], inherited.nodes.map { |node| node.fetch("lifetime") }
  end

  test "invalid wake is refused at its member authoring boundary" do
    result = compile([tool("bad", "read_file", "wake" => "never")])
    assert_equal [{ "code" => "invalid_wake", "path" => "steps[0].wake" }], result.errors
    assert_empty result.nodes
    group = compile([parallel(tool("a"), wake: "never"), model("final")])
    assert_equal [{ "code" => "invalid_wake", "path" => "steps[0].wake" }], group.errors
  end

  test "lifetime inherits the authoring context without bleeding step overrides into siblings" do
    result = compile([
      model("explicit", "lifetime" => "turn"), model("ordinary"),
      parallel(tool("grouped"), tool("escaped", "lifetime" => "conversation"),
        lifetime: "turn", until: "any", key: "race"),
      model("after_group"),
    ])

    assert_predicate result, :valid?, result.errors.inspect
    assert_equal({ "explicit" => "turn", "ordinary" => "conversation", "grouped" => "turn",
      "escaped" => "conversation", "race" => "turn", "after_group" => "conversation" },
      nodes(result).transform_values { |node| node.fetch("lifetime") })
    assert_equal "conversation", result.tip.lifetime

    nested = compile([model("escaped", "lifetime" => "conversation"), model("inherited")],
      seed_tip.with(lifetime: "turn"))
    assert_predicate nested, :valid?, nested.errors.inspect
    assert_equal %w[conversation turn], nested.nodes.map { |node| node.fetch("lifetime") }
  end

  test "invalid lifetime is refused at its member authoring boundary and delegation is kernel only" do
    result = compile([tool("bad", "read_file", "lifetime" => "forever")])
    assert_equal [{ "code" => "invalid_lifetime", "path" => "steps[0].lifetime" }], result.errors
    assert_empty result.nodes
    group = compile([parallel(tool("a"), lifetime: "forever"), model("final")])
    assert_equal [{ "code" => "invalid_lifetime", "path" => "steps[0].lifetime" }], group.errors
    refused = compile([{ "delegation" => { "key" => "child" } }])
    assert_equal "unknown_step_verb", refused.errors.sole.fetch("code")

    internal = compile([Step::Delegation.new(key: "child")], seed_tip.with(detached: true), kernel: true)
    assert_predicate internal, :valid?, internal.errors.inspect
    assert_equal "AgentLoopNodes::DelegationTask", internal.nodes.sole.fetch("type")
    assert_equal "turn", internal.nodes.sole.fetch("lifetime")
    assert_equal "absorb", internal.nodes.sole.fetch("on_failure")
  end

  # From a completed round, as the member door places an envelope: a top-level model step continues
  # the spine and reads what it names; every other leaf is a wait; a group's members are fresh.
  test "the table: every placement's edges, reads, mark and tip, from a completed round" do
    {
      "a tool" => [
        [tool("t")], [%w[rN t]], { "t" => nil }, ["rN", ["t"], []]],
      "an ask" => [
        [ask("q")], [%w[rN q]], { "q" => nil }, ["rN", ["q"], []]],
      "a model reads the spine and consumes" => [
        [model("m")], [%w[rN m]], { "m" => ["rN"] }, ["m", ["m"], []]],
      "tool then model: the model continues the spine; the tool is a wait" => [
        [tool("t"), model("m")], [%w[rN t], %w[t m]], { "m" => %w[rN] }, ["m", ["m"], []]],
      "tool then a model naming it: the tool is a result" => [
        [tool("t"), model("m", "results" => ["t"])], [%w[rN t], %w[t m]], { "m" => %w[rN] }, ["m", ["m"], []],
        { "m" => ["t"] }],
      "tools are waits, never material a model consumes" => [
        [tool("a"), tool("b"), model("m"), tool("c")],
        [%w[rN a], %w[a b], %w[b m], %w[m c]], { "m" => %w[rN] }, ["m", ["c"], []]],
      "a detached tool leaves the tip alone" => [
        [detached(tool("bg")), model("m")], [%w[rN bg], %w[rN m]], { "m" => ["rN"] }, ["m", ["m"], []]],
      "a detached model reads nothing and stays off the spine" => [
        [detached(model("bg")), model("m")], [%w[rN bg], %w[rN m]],
        { "bg" => nil, "m" => ["rN"] }, ["m", ["m"], []]],
      "an all fan: the follower waits on every exit and reads none by position" => [
        [parallel(tool("a"), tool("b")), model("m")],
        [%w[rN a], %w[rN b], %w[a m], %w[b m]], { "m" => %w[rN] }, ["m", ["m"], []]],
      "a fan of model steps: branches are fresh, the synthesis reads what it names" => [
        [parallel(model("b1"), model("b2")), model("synth", "results" => %w[b1 b2])],
        [%w[rN b1], %w[rN b2], %w[b1 synth], %w[b2 synth]],
        { "b1" => nil, "b2" => nil, "synth" => %w[rN] }, ["synth", ["synth"], []], { "synth" => %w[b1 b2] }],
      "a fan then a tool: position waits and nothing accumulates" => [
        [parallel(tool("a"), tool("b")), tool("c")],
        [%w[rN a], %w[rN b], %w[a c], %w[b c]], {}, ["rN", ["c"], []]],
      "a nested [tool, model]: the member is fresh, the follower continues the spine" => [
        [parallel([tool("a1"), model("b1")], tool("x")), model("m")],
        [%w[rN a1], %w[a1 b1], %w[rN x], %w[b1 m], %w[x m]],
        { "b1" => nil, "m" => %w[rN] }, ["m", ["m"], []]],
      "a nested [model, tool]: the follower waits on the tool" => [
        [parallel([model("b1"), tool("a1")]), model("m")],
        [%w[rN b1], %w[b1 a1], %w[a1 m]], { "b1" => nil, "m" => %w[rN] }, ["m", ["m"], []]],
      "a nested [tool, tool]: the follower waits on the last" => [
        [parallel([tool("a1"), tool("a2")]), model("m")],
        [%w[rN a1], %w[a1 a2], %w[a2 m]], { "m" => %w[rN] }, ["m", ["m"], []]],
      "a sequence ending on a detached step: the follower waits on what precedes it" => [
        [parallel([tool("a1"), detached(model("bg"))]), model("m")],
        [%w[rN a1], %w[a1 bg], %w[a1 m]], { "bg" => nil, "m" => %w[rN] }, ["m", ["m"], []]],
      # The two-source fan-in (the bench's O7b): a group is a step of the
      # sequence it sits in, placed at the sequence's local cursor, and each
      # summary names its own inputs.
      "a nested [parallel, model]: each summary names its inputs, the report names both summaries" => [
        [parallel([tool("t"), model("ts", "results" => ["t"])],
          [parallel(tool("l"), tool("ty")), model("qs", "results" => %w[l ty])]),
         model("report", "results" => %w[ts qs])],
        [%w[rN t], %w[t ts], %w[rN l], %w[rN ty], %w[l qs], %w[ty qs], %w[ts report], %w[qs report]],
        { "ts" => nil, "qs" => nil, "report" => %w[rN] }, ["report", ["report"], []],
        { "ts" => ["t"], "qs" => %w[l ty], "report" => %w[ts qs] }],
    }.each do |name, (steps, expected_edges, expected_reads, expected_tip, expected_results)|
      result = compile(steps, after_round)
      assert_predicate result, :valid?, "#{name}: #{result.errors.inspect}"
      assert_equal expected_edges.sort, edges(result).sort, name
      expected_reads.each do |key, keys|
        keys.nil? ? assert_nil(reads(result, key), "#{name}: #{key} reads") :
          assert_equal(keys, reads(result, key), "#{name}: #{key} reads")
      end
      nodes(result).each do |key, node|
        named = expected_results.to_h[key]
        named.nil? ? assert_nil(node["result_from_node_keys"], "#{name}: #{key} results") :
          assert_equal(named, node["result_from_node_keys"], "#{name}: #{key} results")
      end
      assert_equal expected_tip, tip_keys(result.tip), "#{name}: the tip"
    end
  end

  test "the mark has one writer: round on the path, branch inside a group or detached" do
    result = compile([
      model("a"), parallel(model("b"), [tool("t"), model("c")]), detached(model("bg")), model("d"),
    ])
    marks = nodes(result).transform_values { |node| node["continuation_source"] }.compact
    assert_equal({ "a" => "round", "b" => "branch", "c" => "branch", "bg" => "branch", "d" => "round" }, marks)
    assert_equal [true], nodes(result).values.select { |n| n["detached"] }.map { |n| n["node_key"] == "bg" }
  end

  test "a kernel tip's mark and detached are inherited by every row placed" do
    tip = AgentLoops::Tasks::Tip.new(
      spine: at("r1t0-branch", "model_task", "branch"), waits: [at("r1t0-branch", "model_task", "branch")],
      reads: [], mark: Compile::BRANCH, detached: true
    )
    fan = Step::Parallel.new(members: [Step::Tool.new(key: "r2t0", name: "read_file", tool_call_id: "c")])
    result = compile([fan, Step::Model.new(key: "r2", model: MOCK_MODEL)], tip, kernel: true)

    assert_predicate result, :valid?, result.errors.inspect
    assert nodes(result).values.all? { |node| node["detached"] }, "a detached branch's own rounds stay off the frontier"
    assert_equal "branch", nodes(result).fetch("r2")["continuation_source"]
    assert_equal %w[r1t0-branch r2t0], reads(result, "r2")
    assert_equal ["r2", ["r2"], []], tip_keys(result.tip)
  end

  test "a race places one barrier row with the members' exits as its sources" do
    result = compile([parallel(model("a"), model("b"), until: "any", key: "race"), model("reduce")], after_round)

    assert_predicate result, :valid?, result.errors.inspect
    race = nodes(result).fetch("race")
    assert_equal ["AgentLoopNodes::JoinTask", "any", nil, "cancel_losers", "hidden", "propagate"],
      race.values_at("type", "join_mode", "quorum_k", "loser_policy", "transcript_visibility", "on_failure"),
      "a public race cancels its losers; the door's barrier propagates"
    assert_equal [%w[a race], %w[b race], %w[rN a], %w[rN b], %w[race reduce]], edges(result).sort
    assert_equal %w[rN], reads(result, "reduce"), "the follower continues the spine and reads no member"
    assert_nil nodes(result).fetch("reduce")["result_from_node_keys"], "a race reaches a reader only by name"
    assert_equal %w[race race], %w[a b].map { |key| nodes(result).fetch(key)["barrier_key"] }
    assert_equal [{ "parallel" => %w[a b], "key" => "race" }, "reduce"], result.mirror

    quorum = compile([parallel(model("a"), model("b"), model("c"), until: 2, losers: "run_out", on_failure: "absorb"),
                      model("reduce")], after_round)
    barrier = nodes(quorum).values.find { |node| node["join_mode"] }
    assert_equal ["parallel-1", "quorum", 2, "run_out", "absorb"],
      barrier.values_at("node_key", "join_mode", "quorum_k", "loser_policy", "on_failure")
  end

  test "keys are minted pure in position, under the door's prefix" do
    result = compile([
      { "tool" => { "name" => "x" } }, { "model" => { "prompt" => "p", "model" => MOCK_MODEL } },
      { "parallel" => [{ "ask" => { "prompt" => "q" } }, { "tool" => { "name" => "y" } }], "until" => "any" },
      { "model" => { "prompt" => "p", "model" => MOCK_MODEL } },
    ], after_round, mint: "s4-")

    assert_equal %w[s4-tool-1 s4-model-1 s4-ask-1 s4-tool-2 s4-parallel-1 s4-model-2], result.keys
    assert_equal ["s4-tool-1", "s4-model-1", { "parallel" => %w[s4-ask-1 s4-tool-2], "key" => "s4-parallel-1" },
                  "s4-model-2"], result.mirror
  end

  test "the refusal matrix answers every malformed shape at its path" do
    {
      "not-array" => [%w[steps_must_be_an_array]],
      [[]] => [%w[step_must_be_an_object steps[0]]],
      [{ "tool" => { "name" => "x" }, "model" => { "prompt" => "p" } }] => [%w[ambiguous_step steps[0]]],
      [{ "task" => {} }] => [%w[unknown_step_verb steps[0]]],
      [tool("t", "depends_on" => ["x"])] => [%w[edge_authoring_refused steps[0].tool.depends_on]],
      [model("m", "input_from" => ["x"])] => [%w[edge_authoring_refused steps[0].model.input_from]],
      [model("m", "kind" => "model_task")] => [%w[edge_authoring_refused steps[0].model.kind]],
      [tool("t", "prompt" => "please")] => [%w[unknown_step_option steps[0].tool.prompt]],
      [ask("a", "retry" => 1)] => [%w[unknown_step_option steps[0].ask.retry]],
      # A tool step's budget was compiled, rendered and documented but
      # consumed only by the model-step converger (review 2026-09-08 change
      # 6): refused rather than silently lost. The budgeted requeue on the
      # settle's failed arm is the recorded alternative if a consumer asks.
      [tool("t", "retry" => 1)] => [%w[unknown_step_option steps[0].tool.retry]],
      [parallel(tool("t"), "mode" => "any")] => [%w[edge_authoring_refused steps[0].mode]],
      [{ "parallel" => "x" }] => [%w[empty_parallel steps[0]]],
      [parallel(), model("m")] => [%w[empty_parallel steps[0]]],
      [model("a"), model("a")] => [%w[duplicate_task_key steps[1].key]],
      [model("a.b")] => [%w[invalid_task_key steps[0].key]],
      [model("a", "model" => nil)] => [%w[invalid_model steps[0].model]],
      [model("a", "prompt" => 7)] => [%w[invalid_prompt steps[0].prompt]],
      [model("a", "prompt" => nil)] => [%w[prompt_required steps[0].prompt]],
      [model("a", "configuration" => "x")] => [%w[invalid_configuration steps[0].configuration]],
      [{ "tool" => { "name" => "" } }] => [%w[invalid_tool_name steps[0].name]],
      [tool("t", "input" => 5)] => [%w[invalid_tool_input steps[0].input]],
      [tool("t", "tool_call_id" => "c")] => [%w[invalid_tool_call_id steps[0].tool_call_id]],
      [tool("t", "compose")] => [%w[reserved_tool_name steps[0].name]],
      [ask("a", "timeout_ms" => -1)] => [%w[invalid_timeout_ms steps[0].timeout_ms]],
      [model("a", "on_failure" => "explode")] => [%w[invalid_on_failure steps[0].on_failure]],
      [model("a", "visibility" => "loud")] => [%w[invalid_visibility steps[0].visibility]],
      [model("a", "retry" => 9)] => [%w[invalid_retry steps[0].retry]],
      [model("a", "retry" => "2")] => [%w[invalid_retry steps[0].retry]],
      [model("a", "detached" => "yes")] => [%w[invalid_detached steps[0].detached]],
      [parallel(tool("t"), until: "first"), model("m")] => [%w[invalid_until steps[0].until]],
      [parallel(tool("t"), until: 0), model("m")] => [%w[invalid_until steps[0].until]],
      [parallel(tool("a"), tool("b"), until: 3), model("m")] => [%w[unsatisfiable_until steps[0].until]],
      [parallel(detached(tool("a")), until: "any"), model("m")] => [%w[unsatisfiable_until steps[0].until]],
      [parallel(tool("a"), key: "k"), model("m")] => [%w[key_needs_a_race steps[0].key]],
      [parallel(tool("a"), losers: "cancel"), model("m")] => [%w[invalid_losers steps[0].losers]],
      [parallel(tool("a"), on_failure: "absorb"), model("m")] => [%w[invalid_on_failure steps[0].on_failure]],
      [parallel(tool("a"), tool("b"), until: "any", losers: "keep"), model("m")] =>
        [%w[invalid_losers steps[0].losers]],
      [parallel(tool("a"), [tool("b", "input" => 5)]), model("m")] =>
        [%w[invalid_tool_input steps[0].parallel[1][0].input]],
      [parallel(tool("a"), tool("b"))] => [%w[fan_needs_follower steps[0]]],
      [tool("a"), parallel(tool("b"), tool("c"))] => [%w[fan_needs_follower steps[1]]],
    }.each do |steps, expected|
      result = compile(steps, after_round)
      assert_equal expected, result.errors.map { |e| [e["code"], e["path"]].compact }, steps.inspect
    end
  end

  test "a seed of only detached steps has nothing to deliver" do
    result = compile([detached(model("bg"))])
    assert_equal [%w[seed_needs_a_tip steps[0]]], result.errors.map { |e| [e["code"], e["path"]] }

    fine = compile([detached(model("bg"))], after_round)
    assert_predicate fine, :valid?, "an append of only detached steps leaves the tip where it was"
    assert_equal ["rN", ["rN"], []], tip_keys(fine.tip)
  end

  test "the bounds: total steps, a group's width, a follower's waits, and the reads" do
    too_many = Array.new(65) { |i| tool("t#{i}") } + [model("m")]
    assert_equal "too_many_steps", compile(too_many, after_round).errors.sole["code"]

    wide = compile([parallel(*Array.new(33) { |i| tool("w#{i}") }), model("m")], after_round)
    assert_equal %w[too_wide_a_fan steps[0]], wide.errors.sole.values_at("code", "path")

    chain = Array.new(33) { |i| tool("t#{i}") }
    long = compile(chain + [model("m")], after_round)
    assert_predicate long, :valid?, "a chain behind a model is its waits, never its reads"
    assert_equal %w[rN], reads(long, "m")
    naming = compile(chain + [model("m", "results" => Array.new(32) { |i| "t#{i}" })], after_round)
    assert_equal %w[too_many_dependencies steps[33]], naming.errors.sole.values_at("code", "path"),
      "the names and the tip's own wait past the client's 32"

    handed = AgentLoops::Tasks::Tip.new(spine: at("rN"), waits: [at("rN")], mark: Compile::ROUND, detached: false,
      reads: Array.new(Compile::KERNEL_MAX_INPUT_FROM) { |i| at("w#{i}", "tool_task", nil) })
    many_reads = compile([Step::Model.new(key: "w", model: MOCK_MODEL)], handed, kernel: true)
    assert_equal %w[too_many_reads steps[0]], many_reads.errors.sole.values_at("code", "path"),
      "the spine plus a kernel tip's reads past the kernel's bound"

    kernel_fan = Step::Parallel.new(members: Array.new(257) { |i| Step::Tool.new(key: "r1t#{i}", name: "x") })
    over = compile([kernel_fan, Step::Model.new(key: "r1", model: MOCK_MODEL)], after_round, kernel: true)
    assert_equal "too_many_steps", over.errors.first["code"],
      "a 257-call round is past the kernel's own hygiene: the step that asked for it fails"
  end

  test "a kernel author may omit the prompt and end on a fan when a head follows" do
    promptless = compile([Step::Model.new(key: "r1", model: MOCK_MODEL, tools: [READ_TOOL])], seed_tip, kernel: true)
    assert_predicate promptless, :valid?, promptless.errors.inspect
    assert_nil nodes(promptless).fetch("r1")["input_from_node_keys"]
    assert_equal "halt", nodes(promptless).fetch("r1")["on_failure"]

    headed = compile([Step::Parallel.new(members: [Step::Tool.new(key: "a", name: "x"), Step::Tool.new(key: "b", name: "x")])],
      after_round, kernel: true, headed: true)
    assert_predicate headed, :valid?, "the compose call's continuation is the follower"
    assert_equal %w[a b], headed.tip.waits.map(&:key)

    kernel_ask = compile([Step::Ask.new(key: "q", prompt: "which?", on_failure: "propagate")], after_round, kernel: true)
    assert_equal "halt", nodes(kernel_ask).fetch("q")["on_failure"],
      "a model's ask holds the loop on expiry, whatever the author wrote"
  end

  test "the wire's payload bound and the door's tool grammar hold" do
    huge = [tool("t", "input" => { "blob" => "x" * Compile::MAX_TASKS_PAYLOAD_BYTES })]
    assert_equal "steps_payload_too_large", compile(huge, after_round).errors.sole["code"]

    nul = compile([tool("t", "input" => { "s" => "a b" })], after_round)
    assert_equal "invalid_tool_input", nul.errors.sole["code"],
      "a byte the row store cannot hold refuses typed, never an INSERT 500"

    empty_tools = compile([model("m", "tools" => [])], after_round)
    assert_equal "invalid_tools", empty_tools.errors.sole["code"]
  end

  # THE FIRST READ IS THE ROUND CONTINUED: a branch's own continuations are `r<m>` keys off the
  # loop-global counter with no prefix link to their root, so the one row fact the thread's
  # expansion walks is `input_from_node_keys[1]` — the round a continuation continues, which
  # `place_model` always writes first (`reads = [cursor.spine, *cursor.reads]`; a barrier changes
  # the waits and the reads after it, never that first entry). `AgentLoop#spine_tail` rests on the
  # same fact. Pinned across the kernel's own fan — a parallel of tools between the round and its
  # continuation — and across a race's join row.
  test "a kernel continuation's first read is the round it continues, across a barrier too" do
    tip = AgentLoops::Tasks::Tip.new(
      spine: at("rN", "model_task", Compile::BRANCH), waits: [at("rN", "model_task", Compile::BRANCH)],
      reads: [], mark: Compile::BRANCH, detached: false
    )
    fan = Step::Parallel.new(members: [Step::Tool.new(key: "r2t0", name: "x", tool_call_id: "c0"),
      Step::Tool.new(key: "r2t1", name: "x", tool_call_id: "c1")])
    continued = compile([fan, Step::Model.new(key: "r2", model: MOCK_MODEL, tools: [READ_TOOL])], tip, kernel: true)
    assert_predicate continued, :valid?, continued.errors.inspect
    assert_equal %w[rN r2t0 r2t1], reads(continued, "r2")
    assert_equal Compile::BRANCH, nodes(continued).fetch("r2")["continuation_source"],
      "a branch's continuation stays a branch: the mark rides the tip"

    raced = compile([Step::Parallel.new(members: fan.members, until: 1, key: "gate"),
                     Step::Model.new(key: "r2", model: MOCK_MODEL, tools: [READ_TOOL])], tip, kernel: true)
    assert_predicate raced, :valid?, raced.errors.inspect
    assert_equal "rN", reads(raced, "r2").first, "a join row changes what is waited on, never the first read"

    plain = compile([model("m")], after_round("r7"))
    assert_equal "r7", reads(plain, "m").first
  end

  # A RACE REACHES A READER ONLY BY NAME: position hands the step after a race a wait on its barrier
  # and nothing to read, whatever its arms end on; `results: [race]` reads what the race selected.
  # Whatever the shape, a join is never material.
  def script(key, **fields) = { "script" => { "key" => key, "script" => "return null" }.merge(fields.transform_keys(&:to_s)) }
  def stage_arm(tool_key, stage_key) = [tool(tool_key), script(stage_key, "results" => [tool_key])]
  def stage_race = parallel(stage_arm("a", "sa"), stage_arm("b", "sb"), until: "any", key: "race")

  def follower_reads(result, key = "report")
    assert_predicate result, :valid?, result.errors.inspect
    joins = result.nodes.filter_map { |node| node["node_key"] if node["join_mode"] }
    result.nodes.each do |node|
      assert_empty Array(node["input_from_node_keys"]) & joins, "#{node["node_key"]} reads a join as material"
    end
    nodes(result).fetch(key).values_at("input_from_node_keys", "result_from_node_keys")
  end

  test "a model after a race reads nothing of it by position" do
    result = compile([stage_race, model("report")])

    assert_equal [nil, nil], follower_reads(result)
    assert_equal [["race", true]],
      result.edges.select { |edge| edge["to_key"] == "report" }.map { |edge| edge.values_at("from_key", "structural") },
      "the follower waits on the barrier alone and names no stage"

    mixed = compile([parallel(tool("a"), [tool("b"), script("sb")], until: "any", key: "race"), model("report")])
    assert_equal [nil, nil], follower_reads(mixed), "a tool exit is no more material than a stage exit"
  end

  test "a race is read by its name, once, whatever its arms end on" do
    assert_equal [nil, ["race"]], follower_reads(compile([stage_race, model("report", "results" => ["race"])]))

    nested = compile([parallel([parallel(script("x"), script("y"), until: "any", key: "inner")], tool("b"),
      until: "any", key: "outer"), model("report", "results" => ["outer"])])
    assert_equal [nil, ["outer"]], follower_reads(nested), "never the inner join, nor x or y"

    arms = Array.new(17) { |index| stage_arm("t#{index}", "s#{index}") }
    wide = compile([parallel(*arms, until: "any", key: "race"), model("report", "results" => ["race"])])
    assert_equal [nil, ["race"]], follower_reads(wide), "the race read is one read"
  end

  test "an all group's members are read by name" do
    assert_equal [nil, nil], follower_reads(compile([parallel(script("x"), script("y")), model("report")]))
    assert_equal [nil, %w[x y]],
      follower_reads(compile([parallel(script("x"), script("y")), model("report", "results" => %w[x y])]))
  end

  test "a member named explicitly is read alone" do
    assert_equal [nil, ["sb"]], follower_reads(compile([stage_race, model("report", "results" => ["sb"])]))
  end

  test "a follower's results are exactly its names, in its order" do
    result = compile([script("s0"), stage_race, script("after", "results" => ["race"]),
      model("report", "results" => %w[s0 race after])])
    assert_equal [nil, %w[s0 race after]], follower_reads(result)
  end

  READ_TOOL = { "type" => "function",
                "function" => { "name" => "read_file", "parameters" => { "type" => "object" } } }.freeze
end
