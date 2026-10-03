require "test_helper"
require "test_helpers/compose_test_helper"

# `compose` — the graph-authoring tool. A model answers a round by writing a PURE FUNCTION that
# BUILDS a subgraph; the kernel appends it under the call. The WHEN word is `wait` on the CALL: by
# default the subgraph runs DETACHED and its tips reach a later round, and with `wait: true` it is
# spliced BETWEEN the call and that round's continuation, so the turn does not continue until the
# composed work is done and the continuation reads what it produced.
class AgentLoops::ComposeTest < ActiveJob::TestCase
  include InvocationHarness
  include ComposeTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "ordinary composed models retain the calling round visibility" do
    agent_loop = seed(model("round1", "prompt" => "do the work", "visibility" => "collapsed"))
    start!(agent_loop)
    compose_round!(agent_loop, 'g.model({key: "review", prompt: "Review the work."});', wait: true)

    assert_equal "collapsed", node(agent_loop, "r1t0-review").transcript_visibility
  end

  test "a composed wait observes a receipt identity without namespacing its target or changing its timeout" do
    agent_loop = seed(detached(ask("external")), model("round1", "prompt" => "join existing work"))
    start!(agent_loop)
    compose_round!(agent_loop, <<~JS, { "source" => agent_loop.public_id }, wait: true)
      g.wait({task: "external", agent_loop: params.source, key: "observe", timeout_ms: 5000});
    JS
    observer = node(agent_loop, "r1t0-observe")
    assert_equal "dispatched", observer.status
    assert_equal ["external", agent_loop.public_id, 5000],
      [observer.awaited_task_key, observer.awaited_agent_loop_public_id, observer.await_timeout_ms]
    assert_equal "queued", node(agent_loop, "r1").status
    target = node(agent_loop, "external")
    settled = AgentLoops::Parks::Settle.call(node: target, claim_token: target.resolution_token,
      outcome: "completed", content: "the original result")
    assert_predicate settled, :applied?
    schedule!(agent_loop)
    assert_equal "completed", observer.reload.status
    assert_includes observer.output_body.effective_text, "the original result"
    assert_equal "running", node(agent_loop, "r1").status
  end

  # THE FLAGSHIP. Two model branches at once, and the round's continuation
  # reads both — the shape a flat list of tool calls cannot express at
  # all. No barrier row: an `all` fan is a set the follower waits on.
  test "a composed fan is spliced between the call and its continuation" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS, wait: true)
      g.parallel([
        g.model({ model: "dev/mock-text", prompt: "approach A", key: "a" }),
        g.model({ model: "dev/mock-text", prompt: "approach B", key: "b" }),
      ]);
    JS

    keys = agent_loop.agent_loop_nodes.pluck(:node_key).sort
    assert_equal %w[r1 r1t0 r1t0-a r1t0-b round1], keys,
      "the subgraph is namespaced under the call that built it, and an all fan draws no row"

    # The roots hang off the compose call; the continuation hangs off the
    # exits. The subgraph is INSIDE the round, not beside it.
    assert_equal %w[r1t0], sources_of(agent_loop, "r1t0-a")
    assert_equal %w[r1t0 r1t0-a r1t0-b], sources_of(agent_loop, "r1"),
      "the continuation waits on the composed work, not just on the call"
    assert_equal %w[round1 call_c r1t0-a r1t0-b], read_by(agent_loop, "r1"),
      "it READS the branches, in written order"
    assert_equal %w[branch branch], %w[r1t0-a r1t0-b].map { |k| node(agent_loop, k).continuation_source }

    assert_equal "completed", node(agent_loop, "r1t0").status
    assert_match(/Composed 2 tasks: r1t0-a, r1t0-b/, tool_result(agent_loop, "r1t0"))
  end

  # A synthesis step reads the members it names; nothing reaches it by position, and it continues
  # nobody's conversation. What it read is not read again: the waited continuation reads the
  # synthesis alone, because no other step of the envelope is left unread.
  test "a synthesis step reads the members it names, has no input_from, and the head reads the synthesis alone" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS, { "angles" => ["cheapest", "fastest"] }, wait: true)
      const branches = params.angles.map((angle, i) =>
        g.model({ model: "dev/mock-text", prompt: angle, key: "angle" + i })
      );
      g.parallel(branches);
      g.model({ model: "dev/mock-text", prompt: "combine", key: "synth", results: branches });
    JS
    assert_equal %w[round1 call_c r1t0-synth], read_by(agent_loop, "r1")
    assert_equal %w[r1t0-angle0 r1t0-angle1], sources_of(agent_loop, "r1t0-synth"),
      "the synthesis waits on the fan it reads"
    assert_equal %w[r1t0-angle0 r1t0-angle1], node(agent_loop, "r1t0-synth").result_from_node_keys
    assert_nil node(agent_loop, "r1t0-synth").input_from_node_keys,
      "a composed step has no spine: it reads what it names and nothing of the conversation"
    assert_nil node(agent_loop, "r1t0-angle0").input_from_node_keys, "and a member is a fresh agent"
  end

  test "a fan then a tool: the follower reads what it names and the tool it did not name reaches the head" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const a1 = g.tool({ name: "read_file", input: { path: "a" }, key: "a1" });
      const b1 = g.model({ prompt: "review a", key: "b1", results: [a1] });
      const x = g.tool({ name: "read_file", input: { path: "x" }, key: "x" });
      g.parallel([[a1, b1], x]);
      g.tool({ name: "read_file", input: { path: "y" }, key: "y" });
      g.model({ prompt: "combine", key: "m", results: [b1, x] });
    JS

    assert_equal %w[r1t0-a1], sources_of(agent_loop, "r1t0-b1"), "the nested sequence chains inside the group"
    assert_equal %w[r1t0-a1], node(agent_loop, "r1t0-b1").result_from_node_keys
    assert_nil node(agent_loop, "r1t0-b1").input_from_node_keys
    assert_equal %w[r1t0-b1 r1t0-x], sources_of(agent_loop, "r1t0-y"), "the tool waits on every exit"
    assert_equal %w[r1t0-b1 r1t0-x], node(agent_loop, "r1t0-m").result_from_node_keys
    assert_nil node(agent_loop, "r1t0-m").input_from_node_keys, "the follower reads nothing by position"
    assert_equal %w[round1 call_c r1t0-y r1t0-m], read_by(agent_loop, "r1"),
      "every result no step read comes back to the caller"
  end

  # THE TWO-SOURCE FAN-IN (the bench's O7b), spelled the way the nested
  # clause teaches: a group is a step of the sequence it sits in. Through
  # the real door: t→ts, l→qs, ty→qs, ts→report, qs→report; ts names t,
  # qs names l and ty, the report names the two summaries.
  test "a group inside a nested sequence is the fan-in its model step names" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const t = g.tool({ name: "read_file", input: { path: "test.log" }, key: "t" });
      const ts = g.model({ prompt: "summarise the tests", key: "ts", results: [t] });
      const l = g.tool({ name: "read_file", input: { path: "lint.log" }, key: "l" });
      const ty = g.tool({ name: "read_file", input: { path: "types.log" }, key: "ty" });
      const quality = g.parallel([l, ty]);
      const qs = g.model({ prompt: "summarise quality", key: "qs", results: [l, ty] });
      g.parallel([[t, ts], [quality, qs]]);
      g.model({ prompt: "write the report", key: "report", results: [ts, qs] });
    JS

    assert_equal %w[r1t0-t], sources_of(agent_loop, "r1t0-ts")
    assert_equal %w[r1t0-l r1t0-ty], sources_of(agent_loop, "r1t0-qs"), "the inner fan is the summary's whole wait"
    assert_equal %w[r1t0-qs r1t0-ts], sources_of(agent_loop, "r1t0-report")
    assert_equal %w[r1t0-t], node(agent_loop, "r1t0-ts").result_from_node_keys
    assert_equal %w[r1t0-l r1t0-ty], node(agent_loop, "r1t0-qs").result_from_node_keys
    assert_equal %w[r1t0-ts r1t0-qs], node(agent_loop, "r1t0-report").result_from_node_keys
    assert_empty %w[ts qs report].filter_map { |key| node(agent_loop, "r1t0-#{key}").input_from_node_keys }
    assert_equal %w[round1 call_c r1t0-report], read_by(agent_loop, "r1")
  end

  # A script cannot look up which models exist. The first live probe
  # guessed one — plausibly, and wrongly — so a composed step that names
  # no model runs as the model composing it, exactly as a continuation
  # inherits the round it continues.
  test "a composed model step inherits the round's model" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, 'g.model({ prompt: "think about it", key: "t" });', wait: true)

    round = node(agent_loop, "round1")
    composed = node(agent_loop, "r1t0-t")
    assert_equal [round.provider_id, round.model_ref],
      [composed.provider_id, composed.model_ref]
  end

  # A branch that cannot call a tool answers anyway, and nothing in the
  # answer says it was crippled. It inherits the round's whole request
  # surface for the same reason a continuation does — minus the graph
  # verbs: a branch is depth one.
  test "a composed branch inherits the round's request surface, without the graph verbs" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.model({ prompt: "look into it", key: "b" });', wait: true)

    round = node(agent_loop, "round1")
    branch = node(agent_loop, "r1t0-b")
    assert_equal [READ_FILE], branch.tool_definitions, "compose itself is withheld"
    assert_equal round.system_instructions, branch.system_instructions
    assert_equal round.request_options, branch.request_options
    assert_equal "absorb", branch.on_failure, "every model-authored task absorbs its own failure"
    assert_equal "branch", branch.continuation_source,
      "a branch's rounds are its own; the conversation's spine is elsewhere"
  end

  # Narrowing is how a script asks for a smaller branch: `tools` names
  # fewer of the round's tools, and a name the round never declared is refused.
  test "a branch that names its own surface keeps it, and cannot name a tool it was not given" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      g.model({ prompt: "just think", tools: [], instructions: "be terse", key: "b" });
      g.model({ prompt: "read then", tools: ["read_file"], key: "c" });
    JS
    assert_nil node(agent_loop, "r1t0-b").tool_definitions, "tools: [] names none"
    assert_equal "be terse", node(agent_loop, "r1t0-b").system_instructions
    assert_equal [READ_FILE], node(agent_loop, "r1t0-c").tool_definitions

    refused = loop_with_tools
    compose_round!(refused, 'g.model({ prompt: "browse", tools: ["browse"], key: "b" });', wait: true)
    assert refused.agent_loop_nodes.find_by!(node_key: "r1t0").output_summary["is_error"]
    assert_includes tool_result(refused, "r1t0"), %(g.model: "browse" is not one of your tools. You have: compose, read_file)
  end

  test "a g.tool naming a tool outside the round's set is refused at lowering, with the round's tools" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, 'g.tool({ name: "read_file", input: { path: "a" } });', wait: true)

    assert node(agent_loop, "r1t0").output_summary["is_error"]
    assert_includes tool_result(agent_loop, "r1t0"),
      %(g.tool: "read_file" is not one of your tools. You have: compose)
    assert_equal %w[r1 r1t0 round1], agent_loop.agent_loop_nodes.pluck(:node_key).sort, "nothing lowered"
  end

  test "a script that throws answers the call with an error envelope" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, "throw new Error('I changed my mind');", wait: true)

    assert_equal "completed", node(agent_loop, "r1t0").status,
      "the tool RAN; the envelope is data, not a control signal"
    assert node(agent_loop, "r1t0").output_summary["is_error"]
    assert_match(/I changed my mind/, tool_result(agent_loop, "r1t0"))
    assert_equal "running", node(agent_loop, "r1").status,
      "the round continues: a model that wrote a bad program gets to read why"
  end

  # ⚑C2. A compiler refusal is positional; the model wrote lines. A
  # malformed name is the evaluator's refusal now (the door's shape is
  # refused at the line before the kernel sees it); the length rule is the
  # compiler's alone, so that is the refusal this pin reads.
  test "a refused composition is handed back at the script line that built it" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS, wait: true)
      g.model({ model: "dev/mock-text", prompt: "fine", key: "ok" });
      g.model({ model: "dev/#{"m" * 129}", prompt: "bad", key: "oops" });
    JS

    refusal = tool_result(agent_loop, "r1t0")
    assert node(agent_loop, "r1t0").output_summary["is_error"]
    assert_match(/"code": "invalid_model"/, refusal)
    assert_match(/"step": "oops"/, refusal)
    assert_match(/"line": 2/, refusal, "the line of ITS OWN script, not a batch index")
    assert_equal %w[r1 r1t0 round1], agent_loop.agent_loop_nodes.pluck(:node_key).sort,
      "a refused batch appends nothing at all"
  end

  test "the clock and the dice are refused with the reason" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, "g.tool({ name: \"t\", input: { at: Date.now() } });", wait: true)
    assert_match(/resume and replay/, tool_result(agent_loop, "r1t0"))
  end

  # The job may run twice — a retry, a sweep, a worker that died between
  # the append and the settle. The script is PURE, so the rebuild is
  # byte-identical and finding its own keys is the whole recovery.
  test "a second run of the job appends nothing and settles once" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.tool({ name: "read_file", input: {}, key: "r" });', wait: true)
    before = agent_loop.agent_loop_nodes.count

    AgentLoops::Compose::Run.call(node: node(agent_loop, "r1t0"))
    assert_equal before, agent_loop.agent_loop_nodes.count
  end

  # The kernel's name space is not authorable from outside. A client that
  # could author `compose` would get a kernel executor to run a graph
  # mutation on a batch that never passed through a round.
  test "the client door refuses every kernel name, live or reserved" do
    %w[compose spawn nexus.memory.write].each do |name|
      result = compile([tool("t", name)])
      assert_equal "reserved_tool_name", result.errors.sole["code"], name
    end
  end

  # A call nobody can execute parks until its deadline and then SKIPS its
  # dependents under a policy nobody chose. The round's own declared
  # surface is enough to know, which is why no executor-side capability
  # register is needed for it.
  test "a call the round never offered fails at birth, not at its deadline" do
    agent_loop = loop_with_round
    apply_via(step_attempt(agent_loop, "round1"), sse_success("guessing", tool_calls: [
      { id: "call_a", name: "compose", arguments: '{"script":"g.ask({prompt: \\"x\\"});"}' },
      { id: "call_b", name: "read_the_internet", arguments: "{}" },
      { id: "call_c", name: "spawn", arguments: "{}" },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)

    assert_equal "running", node(agent_loop, "r1t0").status,
      "the declared one runs — and `running` is the SURVIVING meaning of the word for a " \
      "tool: a kernel tool nexus executes in its own job, never a call out at a runner"
    assert_equal %w[failed unknown_tool],
      [node(agent_loop, "r1t1").status, node(agent_loop, "r1t1").error_key]
    assert_equal "unknown_tool", node(agent_loop, "r1t2").error_key,
      "a kernel name the round never declared is unknown to it, live or not"
    assert_equal "queued", node(agent_loop, "r1").status,
      "one bad name among good calls must not fail the round"
  end

  # A runner that could claim `compose` could forge a graph mutation nobody authored. A kernel row
  # carries no addressee, so the inbox never lists it and the claim answers `not_addressed_here` —
  # the row, not the registry, decides at both doors.
  test "the runner doors never offer a kernel tool" do
    agent_loop = loop_with_round
    apply_via(step_attempt(agent_loop, "round1"), sse_success("composing", tool_calls: [
      { id: "call_c", name: "compose", arguments: '{"script":"g.ask({prompt: \\"x\\"});"}' },
    ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)

    assert_equal "running", node(agent_loop, "r1t0").status
    assert_nil node(agent_loop, "r1t0").addressed_executor_id
    assert_empty Executors::Inbox.call(executor: suite_runner).tasks
      .map { |row| row[:task_key] }.grep("r1t0")

    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: "r1t0", executor: suite_runner
    ))
    assert_equal :not_addressed_here, claim.outcome
  end
  # A COMPOSED BRANCH IS NOT THE CONVERSATION. When a branch calls a tool
  # the round driver expands it like any other round — which mints a
  # second task marked `continue`. The steer boundary reads that mark to
  # decide which model task is "next", so two marked tasks made "next"
  # ambiguous and the user's words waited on a background branch.
  test "a steer still lands while a composed branch is running" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS, wait: true)
      g.model({ prompt: "go and use a tool", key: "branch" });
    JS

    # The branch answers with a tool call, so the driver expands it.
    branch = node(agent_loop, "r1t0-branch")
    apply_via(step_attempt(agent_loop, "r1t0-branch"),
      sse_success("branching", tool_calls: [
        { id: "call_b", name: "read_file", arguments: '{"path":"a"}' },
      ]))
    AgentLoops::ConvergeTerminalSteps.call
    schedule!(agent_loop)
    assert_equal "completed", branch.reload.status

    loop_input!(agent_loop, acting_user: @human, text: "actually, stop reading")

    checkpoint = AgentLoops::Steers::ConsumeAtCheckpoint.for(
      agent_loop: agent_loop, node: node(agent_loop, "r1")
    )
    refute_empty checkpoint.peek,
      "the round's own continuation must still be the steer boundary - a " \
      "background branch's continuation is not the conversation"
  end

  # ATTACH FORWARDING. A queued consumer of a branch waits on the branch's
  # ROOT, and the root settles the moment it asks for a tool — so the
  # consumer read the tool-call chatter while the answer completed later
  # as a sink nothing selected. Expansion now hands the consumer to the
  # branch's frontier, in the same batch that mints it.
  test "an attached branch's consumer reads its answer, never its first round" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.model({ prompt: "go and use a tool", key: "branch" });', wait: true)
    branch_calls!(agent_loop, "r1t0-branch", "branching")

    assert_equal "queued", node(agent_loop, "r1").status,
      "the continuation keeps waiting: the branch has not answered yet"
    assert_equal %w[r1t0 r1t0-branch r2], sources_of(agent_loop, "r1"),
      "the frontier round is one more thing the continuation waits on"
    assert_equal %w[round1 call_c r2], read_by(agent_loop, "r1"),
      "and it READS the frontier in the root's place"

    settle_tool!(agent_loop, "r2t0", "the file")
    run!(agent_loop, "r2", "the answer")
    run!(agent_loop, "r1", "done")
    texts = request_texts(agent_loop, "r1")
    assert_includes texts, "<task_result task=\"r1t0-branch\" status=\"completed\">\n<prompt>go and use a tool</prompt>\nMock: the answer\n</task_result>",
      "the frontier's last word, delivered under the key the script wrote"
    assert_empty texts.grep(/Mock: branching/), "the first round's chatter never reaches the consumer"
  end

  test "a composed step naming a tool-using model step reads its final text as one envelope carrying its prompt" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const a = g.model({ prompt: "dig", key: "a" });
      g.model({ prompt: "then summarize", key: "b", results: [a] });
    JS
    branch_calls!(agent_loop, "r1t0-a", "digging")

    assert_equal %w[r1t0-a r2], sources_of(agent_loop, "r1t0-b")
    assert_equal %w[r2], node(agent_loop, "r1t0-b").result_from_node_keys, "the name follows the branch's frontier"
    assert_nil node(agent_loop, "r1t0-b").input_from_node_keys

    settle_tool!(agent_loop, "r2t0", "the file")
    run!(agent_loop, "r2", "the final word")
    run!(agent_loop, "r1t0-b", "summarized")
    assert_equal ["<task_result task=\"r1t0-a\" status=\"completed\">\n<prompt>dig</prompt>\nMock: the final word\n</task_result>",
                  "then summarize"], request_texts(agent_loop, "r1t0-b"),
      "the request begins with that envelope under the key the script wrote, never with the other " \
        "step's request or its chatter"
  end

  # TWO FRESH AGENTS: written order is a wait, never a conversation. `m2` starts from its prompt;
  # handed `m1`, it reads m1's answer as one envelope carrying m1's brief — never m1's request.
  test "m1; m2: m2 is fresh, and results: [m1] hands m1's answer as one envelope" do
    agent_loop = loop_with_round
    compose_round!(agent_loop, <<~JS, wait: true)
      const m1 = g.model({ prompt: "draft the plan", key: "m1" });
      g.model({ prompt: "critique it", key: "m2", results: [m1] });
      g.model({ prompt: "say hello", key: "m3" });
    JS
    assert_equal [nil, nil, nil], %w[m1 m2 m3].map { |key| node(agent_loop, "r1t0-#{key}").input_from_node_keys }
    assert_equal %w[r1t0-m1], node(agent_loop, "r1t0-m2").result_from_node_keys
    assert_equal %w[r1t0-m2], sources_of(agent_loop, "r1t0-m3"), "written order is still a wait"

    run!(agent_loop, "r1t0-m1", "the plan")
    run!(agent_loop, "r1t0-m2", "a critique")
    run!(agent_loop, "r1t0-m3", "hello")
    assert_equal ["<task_result task=\"r1t0-m1\" status=\"completed\">\n<prompt>draft the plan</prompt>\nMock: the plan\n</task_result>",
                  "critique it"], request_texts(agent_loop, "r1t0-m2")
    assert_equal ["say hello"], request_texts(agent_loop, "r1t0-m3"), "a step naming nothing reads its prompt alone"
  end

  test "a branch of three rounds forwards twice" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, 'g.model({ prompt: "keep digging", key: "branch" });', wait: true)
    branch_calls!(agent_loop, "r1t0-branch", "first")
    settle_tool!(agent_loop, "r2t0", "one")
    branch_calls!(agent_loop, "r2", "second")

    assert_equal %w[r1t0 r1t0-branch r2 r3], sources_of(agent_loop, "r1")
    assert_equal %w[round1 call_c r3], read_by(agent_loop, "r1"),
      "the read follows the frontier, round after round"

    settle_tool!(agent_loop, "r3t0", "two")
    run!(agent_loop, "r3", "third")
    run!(agent_loop, "r1", "done")
    texts = request_texts(agent_loop, "r1")
    assert_equal 1, texts.grep(/task="r1t0-branch" status="completed"/).length
    assert_equal 1, texts.grep(/Mock: third/).length
    assert_empty texts.grep(/Mock: (first|second)/)
  end

  # A JOIN counts settlements, so a race over tool-using branches was
  # decided by whoever asked for a tool first. The join's edge MOVES to
  # the frontier — in-degree constant — and the loser's continuation is
  # what `cancel_losers` finds abandoned.
  test "a race over tool-using branches settles on an answer, and the loser's continuation is canceled" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const a = g.model({ prompt: "approach A", key: "a" });
      const b = g.model({ prompt: "approach B", key: "b" });
      const race = g.parallel([a, b], { until: "any" });
      g.model({ prompt: "combine", key: "reduce", results: [race] });
    JS
    branch_calls!(agent_loop, "r1t0-a", "A calls")
    branch_calls!(agent_loop, "r1t0-b", "B calls")

    race = node(agent_loop, "r1t0-parallel-1")
    assert_equal %w[any cancel_losers absorb], [race.join_mode, race.loser_policy, race.on_failure],
      "a model's race cancels its losers and absorbs its own starvation"
    assert_equal "queued", race.status, "a member's tool call is not an answer"
    assert_equal %w[r2 r3], sources_of(agent_loop, "r1t0-parallel-1"),
      "the join's edges moved to the frontier; its in-degree did not change"
    assert_equal %w[r1t0-parallel-1], node(agent_loop, "r1t0-reduce").result_from_node_keys,
      "the reduce reads the race it names, whatever its members' frontiers"
    assert_nil node(agent_loop, "r1t0-reduce").input_from_node_keys
    assert_equal %w[round1 call_c r1t0-reduce], read_by(agent_loop, "r1"),
      "the continuation reads the reduce that consumed the race"

    settle_tool!(agent_loop, "r2t0", "the file")
    run!(agent_loop, "r2", "A's answer")

    assert_equal "completed", node(agent_loop, "r1t0-parallel-1").status
    assert_equal %w[canceled join_loser_canceled],
      [node(agent_loop, "r3").status, node(agent_loop, "r3").error_key],
      "the loser is its continuation: its only consumer is the settled join"
    assert_equal "canceled", node(agent_loop, "r3t0").status
    assert_equal "running", node(agent_loop, "r1t0-reduce").status
  end

  # A STEP AFTER A RACE THAT NAMES NOTHING reads only its prompt: position hands it a wait on the
  # barrier and nothing to read. The race's selection is a result no step read, so it comes back to
  # the caller — the waited continuation reads the barrier, which stands for every row in its arms.
  test "a step after a race that names nothing reads only its prompt; the race's selection comes back to the caller" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const m = g.model({ prompt: "approach M", key: "m" });
      const t = g.tool({ name: "read_file", input: { path: "a" }, key: "t" });
      const s = g.script({ key: "s", script: "return {v: results[0].output};", results: [t] });
      g.parallel([m, [t, s]], { until: "any" });
      g.model({ prompt: "reduce", key: "reduce" });
    JS
    assert_equal %w[round1 call_c r1t0-reduce], read_by(agent_loop, "r1")
    assert_equal %w[r1t0-parallel-1], node(agent_loop, "r1").result_from_node_keys,
      "the race comes back as its barrier, never as an arm's step"

    run!(agent_loop, "r1t0-m", "M ANSWER")
    assert_equal "canceled", node(agent_loop, "r1t0-s").status
    assert_equal "running", node(agent_loop, "r1t0-reduce").status
    assert_equal ["reduce"], request_texts(agent_loop, "r1t0-reduce")
  end

  # A VALUE STAGE READING A RACE BY ITS HANDLE: `results: [race]` crosses as the key the builder
  # minted — namespaced like any step's — and waits on the barrier alone, so the stage runs the
  # moment the race settles, the loser is canceled, and `results[0]` is the winner's envelope — where
  # a stage naming every probe waits for the slowest and reads list order.
  test "a value stage reading a race by its handle picks the winner, and the loser is canceled" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const fast = g.tool({ name: "read_file", input: { path: "fast" }, key: "fast" });
      const slow = g.tool({ name: "read_file", input: { path: "slow" }, key: "slow" });
      const race = g.parallel([fast, slow], { until: "any" });
      g.script({ key: "pick", results: [race], script: "const won = results[0]; if (won.status !== 'completed' || won.is_error) throw new Error('no winner'); return won.output;" });
    JS
    pick = node(agent_loop, "r1t0-pick")
    assert_equal ["r1t0-parallel-1"], pick.result_from_node_keys
    assert_equal %w[r1t0-parallel-1], sources_of(agent_loop, "r1t0-pick"), "the stage waits on the barrier alone"

    settle_tool!(agent_loop, "r1t0-fast", "fast answered")
    assert_equal "completed", node(agent_loop, "r1t0-parallel-1").status
    assert_equal %w[canceled join_loser_canceled], node(agent_loop, "r1t0-slow").values_at(:status, :error_key)
    assert_equal "running", pick.reload.status
    AgentLoops::ScriptJob.perform_now(pick.id, pick.execution_generation)
    assert_equal "completed", pick.reload.status
    assert_equal "fast answered", AgentLoops::TaskResultProjection.call(pick).fetch("structured_content")
  end

  # A WAITED GRAPH ENDING ON A RACE OF STAGE EXITS: the splice hands the continuation what the graph
  # left unread, and the race stands for the stages that end its arms — the continuation reads the
  # race's selection, never every arm's stage.
  test "the round after a waited compose whose graph ends on a race of stage exits reads the race" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const arms = ["fast", "slow"].map((host) => {
        const probe = g.tool({ name: "read_file", input: { path: host }, key: host });
        return [probe, g.script({ key: "wrap-" + host, results: [probe], script: "return results[0].output;" })];
      });
      g.parallel(arms, { until: "any" });
    JS

    assert_equal ["r1t0-parallel-1"], node(agent_loop, "r1").result_from_node_keys
  end

  # ONE SET AT ONE MOMENT: the same script, waited and detached, hands back what no step read —
  # to the waited head when the chain it waits on ends, and to the wake once that chain settles;
  # the step it names is read there and comes back from neither.
  test "wait: true and detached deliver the same set at the same moment" do
    script = <<~JS
      const a = g.tool({ name: "read_file", input: { path: "a" }, key: "a" });
      g.model({ prompt: "summarise a", key: "s", results: [a] });
      g.tool({ name: "read_file", input: { path: "b" }, key: "b" });
    JS
    waited = loop_with_tools
    compose_round!(waited, script, wait: true)
    assert_equal %w[round1 call_c r1t0-s r1t0-b], read_by(waited, "r1")
    assert_equal %w[r1t0 r1t0-b], sources_of(waited, "r1"), "the head waits on the chain's end"

    detached = loop_with_tools
    compose_round!(detached, script)
    run!(detached, "r1", "my part is done")
    settle_tool!(detached, "r1t0-a", "the file")
    run!(detached, "r1t0-s", "a summary")
    assert_nil detached.agent_loop_nodes.find_by(node_key: "w1"), "the chain has not ended: b is still live"
    settle_tool!(detached, "r1t0-b", "the other file")
    assert_equal %w[r1 r1t0-s r1t0-b], node(detached, "w1").input_from_node_keys,
      "the set the waited head reads, in one wake"
  end

  # THE RECEIPT NAMES A FORGOTTEN HAND-OFF where it was written: each model step that reads only its
  # prompt, by the script's own line and the start of its prompt — a compile-time fact, no judgment,
  # and never a generated key the author would have to count to.
  test "the receipt names each model step that reads only its prompt by its line" do
    agent_loop = loop_with_tools
    compose_round!(agent_loop, <<~JS, wait: true)
      const a = g.tool({ name: "read_file", input: { path: "a" }, key: "a" });
      g.model({ prompt: "Review the patch for correctness, style and naming in every changed file.", key: "r" });
      g.model({ prompt: "Summarise it", key: "s", results: [a] });
      g.parallel([g.model({ prompt: 'look "again"', key: "p" })]);
    JS

    assert_equal "Composed 4 tasks: r1t0-a, r1t0-r, r1t0-s, r1t0-p.\n" \
      "Line 2 g.model(\"Review the patch for correctness, style and naming in every…\") starts from its prompt alone.\n" \
      "Line 4 g.model(\"look \\\"again\\\"\") starts from its prompt alone.\n" \
      "Their results reach you in the next round.\n" \
      "Task reference: agent_loop=\"#{agent_loop.public_id}\", task=\"r1t0\".", tool_result(agent_loop, "r1t0")
  end

  # DECLARING `compose` IS THE INTENDED GESTURE (⚑C3) — but declaring it
  # with a DIFFERENT description silently substitutes the kernel's
  # executor behind the model's back, and pays for a second cached
  # prefix describing a tool that does not behave that way. The registry
  # publishes the canonical bytes precisely so every client sends the
  # same ones; nothing enforced it until now.
  test "a kernel tool may be declared, but only as the registry publishes it" do
    canonical = compile([model("m", "tools" => [Nexus::Compose::DEFINITION])])
    assert_predicate canonical, :valid?, "declaring compose is how an agent enables it"

    shadowed = Nexus::Compose::DEFINITION.deep_dup
    shadowed["function"]["description"] = "my own compose, which does something else"
    result = compile([model("m", "tools" => [shadowed])])
    assert_equal "kernel_tool_redefined", result.errors.sole["code"]
    assert_equal "steps[0].tools", result.errors.sole["path"]
  end
end
