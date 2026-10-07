require "test_helper"

class AgentRuns::TaskReferencesTest < ActiveSupport::TestCase
  Compile = AgentRuns::Tasks::Compile
  Tip = AgentRuns::Tasks::Tip
  Known = AgentRuns::Tasks::Known
  Step = AgentRuns::Tasks::Step

  test "peer consumers share producers without waiting for one another" do
    result = compile([
      { "parallel" => [tool("a"), tool("b"), model("c", results: ["a"]),
                       model("d", results: %w[a b])] }, model("report"),
    ])
    assert_predicate result, :valid?, result.errors.inspect
    edges = result.edges.to_h { |edge| [[edge["from_key"], edge["to_key"]], edge["structural"]] }
    assert_equal false, edges.fetch(%w[a c])
    assert_equal false, edges.fetch(%w[a d])
    assert_equal false, edges.fetch(%w[b d])
    refute edges.key?(%w[c d])
    assert_equal %w[a b], result.nodes.find { |node| node["node_key"] == "d" }.fetch("result_from_node_keys")
  end

  test "waits add no material and structural edges take precedence over references" do
    result = compile([tool("a"), tool("b", after: ["a"]), model("c", after: ["a"])])
    assert_predicate result, :valid?, result.errors.inspect
    assert_equal true, result.edges.find { |edge| edge.values_at("from_key", "to_key") == %w[a b] }.fetch("structural")
    assert_nil result.nodes.last["result_from_node_keys"]
    assert_nil result.nodes.last["input_from_node_keys"], "neither position nor after hands the model a tool's output"
  end

  test "only preceding leaves and races in this compiled envelope may be referenced" do
    [
      [model("a", results: ["a"])],
      [model("a", results: ["b"]), tool("b")],
      [tool("a"), model("b", results: %w[a a])],
      [{ "parallel" => [tool("a"), tool("b", after: ["race"])], "until" => "any", "key" => "race" }],
      [{ "parallel" => [tool("a"), model("b", results: ["race"])], "until" => "any", "key" => "race" }],
      [model("c", results: ["race"]), { "parallel" => [tool("a"), tool("b")], "until" => "any", "key" => "race" }],
      [{ "parallel" => [tool("a"), tool("b")], "key" => "fan" }, model("c", results: ["fan"])],
    ].each do |steps|
      result = compile(steps)
      refute_predicate result, :valid?, steps.inspect
      assert_empty result.nodes
    end
    tip = Tip.seed(Compile::ROUND).with(waits: [Known.new(key: "old", kind: "tool_task", mark: nil)])
    refute_predicate compile([model("c", results: ["old"])], tip: tip), :valid?
  end

  # A PLACED RACE IS ONE STEP A LATER STEP MAY NAME: `after` and `results` wait on its barrier alone —
  # no member is waited on or read by name, so a consumer never keeps a loser alive — and `results`
  # names the barrier, which reads what the race selected.
  test "a placed race is referenced by its barrier alone" do
    result = compile([
      { "parallel" => [tool("a"), tool("b")], "until" => "any", "key" => "race" },
      tool("x"), model("c", results: ["race"]), model("s", results: ["race"]), tool("y", after: ["race"]),
    ])
    assert_predicate result, :valid?, result.errors.inspect
    edges = result.edges.to_h { |edge| [[edge["from_key"], edge["to_key"]], edge["structural"]] }
    assert_equal true, edges.fetch(%w[race x])
    assert_equal false, edges.fetch(%w[race c])
    assert_equal false, edges.fetch(%w[race s])
    assert_equal false, edges.fetch(%w[race y])
    %w[c s y].each do |reader|
      assert_empty edges.keys.select { |from, to| to == reader && %w[a b].include?(from) }, "#{reader} names no member"
    end
    rows = result.nodes.index_by { |node| node["node_key"] }
    assert_equal ["race"], rows.fetch("c").fetch("result_from_node_keys")
    assert_equal ["race"], rows.fetch("s").fetch("result_from_node_keys")
    assert_nil rows.fetch("y")["result_from_node_keys"], "after adds a wait and no result"

    follower = compile([{ "parallel" => [tool("a"), tool("b")], "until" => 1, "key" => "race" },
      model("c", results: ["race"])])
    assert_predicate follower, :valid?, follower.errors.inspect
    assert_equal [true], follower.edges.select { |edge| edge["to_key"] == "c" }.map { |edge| edge["structural"] },
      "a reader placed right after the race waits on it once, structurally"
  end

  test "a tool's returned value reaches a model only when named" do
    unnamed = compile([tool("a"), tool("s"), model("report")])
    assert_predicate unnamed, :valid?, unnamed.errors.inspect
    assert_nil unnamed.nodes.last["result_from_node_keys"]
    assert_nil unnamed.nodes.last["input_from_node_keys"]

    named = compile([tool("a"), tool("s"), model("report", results: ["s"])])
    assert_predicate named, :valid?, named.errors.inspect
    assert_equal ["s"], named.nodes.last.fetch("result_from_node_keys")
    assert_nil named.nodes.last["input_from_node_keys"]
  end

  # THE LOOP'S OWN CONTINUATION: the one leaf a later model reads by position is the round's own
  # paired call — the kernel alone writes a `tool_call_id`, ExpandRound's fan carries it — so the
  # continuation reads the round it continues and its calls, and nothing an author placed.
  test "a leaf is material only as the round's own paired call" do
    paired = compile([Step::Tool.new(key: "t", name: "read", tool_call_id: "c1"), continuation], tip: mainlined, kernel: true)
    assert_predicate paired, :valid?, paired.errors.inspect
    assert_equal %w[round t], paired.nodes.last.fetch("input_from_node_keys")

    authored = compile([Step::Tool.new(key: "t", name: "read"), continuation], tip: mainlined, kernel: true)
    assert_predicate authored, :valid?, authored.errors.inspect
    assert_equal %w[round], authored.nodes.last.fetch("input_from_node_keys")
    assert_nil authored.nodes.last["result_from_node_keys"]
  end

  # A MEMBER IS A FRESH AGENT: a group's entry clears the mainline on every surface, so a member model
  # starts from its prompt, and the step after the group waits on every member and reads what it names.
  test "a group's members are fresh on every surface and the step after it reads none by position" do
    named = compile([{ "parallel" => [model("m1"), model("m2")] }, model("m3", results: %w[m1 m2])], tip: mainlined)
    assert_predicate named, :valid?, named.errors.inspect
    rows = named.nodes.index_by { |node| node["node_key"] }
    assert_nil rows.fetch("m1")["input_from_node_keys"]
    assert_nil rows.fetch("m2")["input_from_node_keys"]
    assert_equal %w[branch branch], %w[m1 m2].map { |key| rows.fetch(key).fetch("continuation_source") }
    assert_equal ["round"], rows.fetch("m3").fetch("input_from_node_keys"), "the follower continues the mainline"
    assert_equal %w[m1 m2], rows.fetch("m3").fetch("result_from_node_keys")
    assert_equal [%w[m1 m3], %w[m2 m3]],
      named.edges.select { |edge| edge["to_key"] == "m3" }.map { |edge| edge.values_at("from_key", "to_key") }.sort,
      "and waits on every member"

    unnamed = compile([{ "parallel" => [model("m1"), model("m2")] }, model("m3")], tip: mainlined)
    assert_predicate unnamed, :valid?, unnamed.errors.inspect
    follower = unnamed.nodes.index_by { |node| node["node_key"] }.fetch("m3")
    assert_equal ["round"], follower.fetch("input_from_node_keys")
    assert_nil follower["result_from_node_keys"]
  end

  test "a door model step continues the mainline and reads authored material only by name" do
    positional = compile([tool("t"), model("m")], tip: mainlined)
    assert_predicate positional, :valid?, positional.errors.inspect
    assert_equal ["round"], positional.nodes.last.fetch("input_from_node_keys")
    assert_nil positional.nodes.last["result_from_node_keys"]

    named = compile([tool("t"), model("m", results: ["t"])], tip: mainlined)
    assert_predicate named, :valid?, named.errors.inspect
    assert_equal ["round"], named.nodes.last.fetch("input_from_node_keys")
    assert_equal ["t"], named.nodes.last.fetch("result_from_node_keys")
  end

  # THE DOOR'S ONE WIDENING: a client driving the loop hands a value from one append to the next by
  # key, so an authored envelope may name any persisted row; the name is a result and a wait. The
  # kernel's own envelopes hand values through their tips and name nothing they did not place.
  test "a door envelope names a row of an earlier append; a kernel envelope cannot" do
    @workspace = workspaces(:shared)
    @human = users(:member)
    agent_run = seed(tool("c1"), tool("c2"))
    grow!(agent_run, model("m", results: ["c1"]))
    reader = agent_run.agent_run_tasks.find_by!(node_key: "m")
    assert_equal ["c1"], reader.result_from_node_keys
    assert_nil reader.input_from_node_keys
    edges = reader.incoming_edges.includes(:from_node).to_h { |edge| [edge.from_node.node_key, edge.structural] }
    assert_equal({ "c2" => true, "c1" => false }, edges, "the named row is a wait beside the tip's")

    refused = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel", tip: Tip.seed(Compile::BRANCH),
      steps: [Step::Model.new(key: "k", model: MOCK_MODEL, prompt: "p", results: ["c1"])]
    ))
    assert_equal :invalid_steps, refused.outcome
    assert_equal "unknown_task_reference", refused.errors.sole.fetch("code")
    refute agent_run.agent_run_tasks.exists?(node_key: "k")
  end

  # THE BARRIER STANDS FOR ITS ARMS: every row placed inside a race's arms, at any depth, carries the
  # nearest race's key, the persisted fact that says "this row is an arm of that race".
  test "every row in a race's arms carries the barrier's key" do
    result = compile([{ "parallel" => [[tool("t1"), model("m1")], [tool("t2"), model("m2")]], "until" => "any",
                        "key" => "race" }, model("after")])
    assert_predicate result, :valid?, result.errors.inspect
    rows = result.nodes.index_by { |node| node["node_key"] }
    assert_equal %w[race race race race], %w[t1 m1 t2 m2].map { |key| rows.fetch(key)["barrier_key"] }
    assert_nil rows.fetch("race")["barrier_key"]
    assert_nil rows.fetch("after")["barrier_key"]

    nested = compile([{ "parallel" => [
      [tool("t1"), { "parallel" => [tool("i1"), tool("i2")], "until" => "any", "key" => "inner" }],
      [tool("t2"), { "parallel" => [tool("f1"), tool("f2")] }],
    ], "until" => "any", "key" => "outer" }, model("after")])
    assert_predicate nested, :valid?, nested.errors.inspect
    rows = nested.nodes.index_by { |node| node["node_key"] }
    assert_equal %w[inner inner], %w[i1 i2].map { |key| rows.fetch(key)["barrier_key"] }, "the nearest race"
    assert_equal %w[outer outer outer outer outer], %w[t1 inner t2 f1 f2].map { |key| rows.fetch(key)["barrier_key"] },
      "an all group inside an arm is the arm's, and so is the inner barrier"
    assert_nil rows.fetch("outer")["barrier_key"]

    fan = compile([{ "parallel" => [tool("a"), tool("b")] }, model("after")])
    assert_empty fan.nodes.filter_map { |node| node["barrier_key"] }, "an all group places no barrier"
  end

  test "physical generated keys replace local names in edges and result slots" do
    generated = 0
    result = compile([tool("a"), model("b", results: ["a"])],
      key_generator: -> { "generated-#{generated += 1}" })
    assert_predicate result, :valid?, result.errors.inspect
    assert_equal %w[generated-1 generated-2], result.keys
    assert_equal ["generated-1"], result.nodes.last.fetch("result_from_node_keys")
    assert_equal %w[generated-1 generated-2], result.edges.sole.values_at("from_key", "to_key")
  end

  test "a standalone tool continuation needs no default model for tool-only work" do
    [{}, { "tools" => [{ "type" => "function", "function" => {
      "name" => "read", "parameters" => { "type" => "object" },
    } }] }].each do |defaults|
      result = compile([tool("program", model_defaults: defaults)])
      assert_predicate result, :valid?, result.errors.inspect
      assert_equal defaults, result.nodes.sole.fetch("operation_context")
    end
  end

  test "the retired script step has no public authoring path" do
    result = compile([{ "script" => { "script" => "return null" } }])
    refute_predicate result, :valid?
    assert_equal "unknown_step_verb", result.errors.sole.fetch("code")
  end

  private

    def compile(steps, tip: Tip.seed(Compile::ROUND), **options) = Compile.call(steps, tip, **options)

    # A door-shaped tip: the loop's mainline tail, waited on and continued.
    def mainlined
      round = Known.new(key: "round", kind: "model_task", mark: Compile::ROUND)
      Tip.new(mainline: round, waits: [round], reads: [], mark: Compile::ROUND, detached: false)
    end

    def continuation = Step::Model.new(key: "next", model: MOCK_MODEL)
    def tool(key, **fields) = { "tool" => { "key" => key, "name" => "read" }.merge(fields.stringify_keys) }
    def model(key, **fields)
      { "model" => { "key" => key, "prompt" => "Report", "model" => { "model" => "dev/mock-text" } }
        .merge(fields.stringify_keys) }
    end
end
