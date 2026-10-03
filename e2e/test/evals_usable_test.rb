require_relative "executed_plan_scenarios"
require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

# THE FLOOR'S COMPOSE BAR, PROVED ON PAPER: USABLE generation, read per compose call on the graph
# the kernel ran — the kernel settled the call without an error, it placed at least one node, every
# stage source parses (statically over the script's stages and what a result-free stage places, and
# from the kernel's `script_syntax_error` on a stage it ran), and at least one placed node is not a
# stage that failed on its own script. The bar reads the RUN — green when some compose call met
# it, else the first call's red — and `usable_on_call` names the call that first met it. The tier
# the lane stamps picks the bar; a trace with no tier reads the picture, as every record before the
# stamp was scored.
class EvalsUsableTest < Minitest::Test
  include EvalsFixtureBench
  P = E2E::Evals::Predicates
  D = E2E::Evals::Drawing
  W = EvalsDrawings
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  FLOOR = { "tier" => E2E::Evals::Bench::FLOOR }.freeze
  STRONG = { "tier" => E2E::Evals::Bench::STRONG }.freeze
  PLANS = ExecutedPlanScenarios.all.freeze
  # The keys the kernel gives the steps a stage places.
  UUIDS = (1..3).map { |i| "00000000-0000-7000-8000-00000000010#{i}" }.freeze
  # A compose call that placed nothing: the round, the call, its continuation.
  REFUSED_ALONE = D.graph(
    [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
     D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
    [%w[r1 r1t0], %w[r1t0 r2]]
  )

  def test_a_first_call_that_placed_its_plan_is_usable
    trace = W.compose_trace(W::SCRIPTS["O7"])
    assert_equal true, P.compose_usable(trace)
    assert_equal 1, P.usable_on_call(trace)
  end

  # Every authored route graph contains a usable plan, including a nested stage that failed
  # on the greps' output (`failed_stage`) among them, forgiven because the greps it read still stand.
  def test_every_authored_plan_reads_usable
    PLANS.each do |name, fixture|
      assert_equal true, P.compose_usable(fixture_trace(fixture)), name
    end
    failed = PLANS.fetch("failed_stage")
    assert_includes fixture_trace(failed).under(failed["call"]).map { |node| node["status"] }, "failed"
  end

  # THE RUN IS THE BAR: a refused first call is green on the floor when a later call of the run met
  # the bar, and the record says which call first met it, so the first-call rate stays visible. The
  # kernel settles a refusal `completed` with an error result; a call that failed outright reads its
  # error key.
  def test_a_refused_first_call_is_green_when_a_later_call_met_the_bar
    trace = two_calls(refused_call)
    assert_equal true, P.compose_usable(trace)
    assert_equal 2, P.usable_on_call(trace)
    verdict = CORPUS.find("compose-three-stage-pairing").expected.verdict(trace.with_facts(FLOOR))
    assert_equal [true, true], [verdict.reached, verdict.succeeded], "the floor's success is the run's"
    assert_equal 2, verdict.facts.fetch("usable_on_call"), "the recovery rides the record"
    failed = two_calls(D.tool("r1t0", "compose", after: ["r1"], status: "failed", input: { "script" => "x" })
      .merge("error" => { "key" => "approval_denied" }))
    assert_equal true, P.compose_usable(failed)
    assert_equal 2, P.usable_on_call(failed)
    assert_equal "no compose call to read", P.compose_usable(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
  end

  # A RUN WHOSE EVERY CALL MISSED THE BAR IS RED IN THE FIRST CALL'S WORDS: the attempt the run began
  # with names the failure, and no call is recorded as having met the bar.
  def test_a_run_whose_every_call_missed_the_bar_reads_the_first_calls_red
    alone = D.trace(REFUSED_ALONE, [refused_call], [])
    assert_equal "the kernel refused the compose call r1t0: its result is an error", P.compose_usable(alone)
    assert_nil P.usable_on_call(alone), "no call met the bar"
    second = D.tool("r2t0", "compose", after: ["r2"], input: { "script" => "const files = [];" })
    graph = D.graph([*REFUSED_ALONE["nodes"], D.n("r2t0", "tool_task", expansion_parent: "r2")],
      [*REFUSED_ALONE["edges"].map(&:values), %w[r2 r2t0]])
    both = D.trace(graph, [refused_call, second], [])
    assert_equal "the kernel refused the compose call r1t0: its result is an error", P.compose_usable(both)
    assert_nil P.usable_on_call(both)
    verdict = CORPUS.find("compose-three-stage-pairing").expected.verdict(both.with_facts(FLOOR))
    assert_equal [true, false], [verdict.reached, verdict.succeeded]
    failed = D.tool("r1t0", "compose", after: ["r1"], status: "failed", input: { "script" => "x" })
      .merge("error" => { "key" => "approval_denied" })
    assert_equal 'the compose call r1t0 failed: "approval_denied"', P.compose_usable(D.trace(REFUSED_ALONE, [failed], [])),
      "a call that failed outright reads its error key"
  end

  # A stored trace from before the kernel refused a script that builds no step
  # (`Nexus::Compose::Evaluator::NO_STEP`) holds that call settled as a success: it placed nothing.
  def test_a_call_that_placed_nothing_is_not_usable
    trace = D.trace(REFUSED_ALONE, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "const files = [];" })], [])
    assert_equal "the compose call r1t0 placed nothing", P.compose_usable(trace)
    assert_nil P.usable_on_call(trace)
  end

  # A STAGE WHOSE SOURCE DOES NOT PARSE, READ STATICALLY: the stage never ran (the stop canceled it),
  # so the graph says nothing of its source; the script's own text does, through the stage run the
  # kernel would make. A failure on the empty results — a property of an envelope that is not there
  # — is the empty list's, never the stage's.
  def test_a_stage_that_does_not_parse_is_read_off_the_script
    script = <<~'JS'
      const listing = g.tool({ name: "bash", input: { command: "ls lib" } });
      g.script({ results: [listing], script: "return results[0].output +;" });
    JS
    trace = staged(script, [n("r1t0-script-1", "script_task", status: "canceled", result_from: ["r1t0-tool-1"])])
    assert_match(/\Astage script-1 of r1t0 does not parse: SyntaxError/, P.compose_usable(trace))
    nested = <<~'JS'
      g.tool({ name: "bash", input: { command: "ls lib" } });
      g.script({ script: "g.script({ script: 'return (;' });" });
    JS
    expanded = staged(nested, [n("r1t0-script-1", "script_task"), n(UUIDS.first, "script_task", status: "canceled", parent: "r1t0-script-1")])
    assert_match(%r{\Astage script-1/script-1 of r1t0 does not parse}, P.compose_usable(expanded),
      "a stage a result-free stage places is read too: its source is known before the run")
    data = <<~'JS'
      const listing = g.tool({ name: "bash", input: { command: "ls lib" } });
      g.script({ results: [listing], script: "const r = results[0]; return JSON.parse(r ? r.output : '{');" });
    JS
    assert_equal true, P.compose_usable(staged(data, [n("r1t0-script-1", "script_task", result_from: ["r1t0-tool-1"])]))
  end

  # A STAGE WHOSE SOURCE DOES NOT PARSE, READ FROM THE KERNEL: a result-reading stage placed a stage
  # whose script is a tool's output, which no text can know; the kernel ran it and said
  # `script_syntax_error`. The tool the call placed still stands, so only the parse fails the bar.
  def test_a_stage_the_kernel_failed_with_script_syntax_error_is_not_usable
    script = <<~'JS'
      const listing = g.tool({ name: "bash", input: { command: "cat stage.js" } });
      g.script({ results: [listing], script: "g.script({ script: results[0].output });" });
    JS
    placed = [n("r1t0-script-1", "script_task", result_from: ["r1t0-tool-1"]),
              n(UUIDS.first, "script_task", status: "failed", error_key: "script_syntax_error", parent: "r1t0-script-1")]
    assert_equal "stage #{UUIDS.first} under r1t0 does not parse: the kernel failed it script_syntax_error",
      P.compose_usable(staged(script, placed))
    ran_on_data = placed.map { |node| node["key"] == UUIDS.first ? node.merge("error_key" => "script_error") : node }
    assert_equal true, P.compose_usable(staged(script, ran_on_data)), "a stage that failed on data is forgiven while another node stands"
  end

  def test_a_call_whose_every_placed_node_is_a_failed_stage_is_not_usable
    trace = D.trace(D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
       D.n("r1t0-script-1", "script_task", status: "failed", error_key: "script_error", expansion_parent: "r1t0"),
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
      [%w[r1 r1t0], %w[r1t0 r1t0-script-1], %w[r1t0 r2]]
    ), [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.script({ script: \"throw new Error('no plan');\" });" })], [])
    assert_equal "nothing r1t0 placed stands: the stages that did its work failed on their own scripts: r1t0-script-1(failed script_error)",
      P.compose_usable(trace)
  end

  # A STAGE THAT EXPANDED STANDS FOR NOTHING: the kernel's splice hands its place to what it placed,
  # so the whole-plan wrapper around a stage that fails on its own script reads as the flat stage
  # does; a wrapper that also placed a tool still stands through the tool.
  def test_a_stage_that_expanded_stands_only_through_what_it_placed
    wrapper = "g.script({ script: #{JSON.generate("g.script({ script: \"throw new Error('no plan');\" });")} });"
    inner = n(UUIDS.first, "script_task", status: "failed", error_key: "script_error", parent: "r1t0-script-1")
    assert_equal "nothing r1t0 placed stands: the stages that did its work failed on their own scripts: #{UUIDS.first}(failed script_error)",
      P.compose_usable(placed(wrapper, [n("r1t0-script-1", "script_task"), inner]))
    beside = "g.script({ script: #{JSON.generate("g.tool({ name: \"bash\", input: { command: \"ls\" } }); g.script({ script: \"throw new Error('no plan');\" });")} });"
    tool = n(UUIDS[1], "tool_task", parent: "r1t0-script-1")
    assert_equal true, P.compose_usable(placed(beside, [n("r1t0-script-1", "script_task"), tool, inner]))
  end

  # A RACE'S JOIN IS THE KERNEL'S BARRIER, NOT WORK: when every member stage failed on its own script
  # the join starves, and the race reads as the plain group of the same stages does.
  def test_a_race_whose_every_member_failed_on_its_own_script_is_not_usable
    race = <<~'JS'
      g.parallel([g.script({ script: "throw new Error('a');" }), g.script({ script: "throw new Error('b');" })], { until: "any" });
    JS
    stages = [n("r1t0-script-1", "script_task", status: "failed", error_key: "script_error"),
              n("r1t0-script-2", "script_task", status: "failed", error_key: "script_error"),
              n("r1t0-parallel-1", "join_task", status: "failed", error_key: "join_starved")]
    assert_equal "nothing r1t0 placed stands: the stages that did its work failed on their own scripts: " \
      "r1t0-script-1(failed script_error), r1t0-script-2(failed script_error)", P.compose_usable(placed(race, stages))
    follower = race.sub(");\n", ");\ng.model({ prompt: \"Say which mirror answered.\" });\n")
    assert_equal true, P.compose_usable(placed(follower, [*stages, n("r1t0-model-1", "model_task")]))
  end

  # A TOOL OR MODEL STEP THAT FAILED AT RUN TIME is a placed node that stands: its failure is the
  # run's, never the generation's — only a stage failing on its own script counts against the bar.
  def test_a_step_that_failed_at_run_time_still_stands
    script = 'g.tool({ name: "bash", input: { command: "bin/probe alpha" } });'
    assert_equal true, P.compose_usable(placed(script, [n("r1t0-tool-1", "tool_task", status: "failed", error_key: "executor_revoked")]))
  end

  # A PLAN THE KERNEL PLACED FOR A SCRIPT THE HARNESS CANNOT BUILD is the harness's own fault: the
  # predicate raises and the lane files it as a lane bug.
  def test_a_placed_plan_whose_script_the_harness_refuses_raises
    trace = W.compose_trace("g.model({ prompt: ", graph: W::FAN_GRAPH)
    assert_raises(E2E::ComposeBench::Executed::Drifted) { P.compose_usable(trace) }
    assert_raises(E2E::ComposeBench::Executed::Drifted, "the strong tier runs the floor's guard too") do
      P.compose_bar(trace.with_facts(STRONG), "O1")
    end
  end

  # THE TIER PICKS THE BAR: the floor reads usable generation, the strong tier the picture — one
  # implementation, `compose_picture` — and a trace with no tier fact (every record before the lane
  # stamped one) reads the picture, as it was scored then. The lane's stamp is `Bench#tier_fact`.
  def test_the_tier_fact_picks_the_bar
    wrong = W.compose_trace(W::SCRIPTS["O7"])
    picture = P.compose_picture(wrong, "O1")
    assert_match(/the picture is not the objective's/, picture)
    assert_equal true, P.compose_bar(wrong.with_facts(FLOOR), "O1")
    assert_equal picture, P.compose_bar(wrong.with_facts(STRONG), "O1")
    assert_equal picture, P.compose_bar(wrong, "O1"), "no tier fact: the picture"
    right = W.compose_trace(W::SCRIPTS["O1"])
    assert_equal true, P.compose_bar(right.with_facts(STRONG), "O1")
    assert_equal true, P.compose_bar(wrong.with_facts(BENCH.tier_fact("fixture/floor")), "O1")
    assert_equal picture, P.compose_bar(wrong.with_facts(BENCH.tier_fact("fixture/strong")), "O1")
  end

  private

    def n(key, kind, status: "completed", error_key: nil, parent: "r1t0", result_from: nil)
      D.n(key, kind, status: status, error_key: error_key, expansion_parent: parent, result_from: result_from)
    end

    # A refusal as the kernel settles one: `completed`, with an error result.
    def refused_call
      D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.model({ prompt: " })
        .merge("result" => { "resolved" => true, "is_error" => true })
    end

    # The first call `first` placed nothing; the second, made by its continuation, placed O7's plan.
    def two_calls(first)
      second = D.composed(W::SCRIPTS["O7"], call: "r2t0")
      graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), *second["nodes"]],
        [%w[r1 r1t0], %w[r1t0 r2], *second["edges"].map(&:values)])
      D.trace(graph, [first, D.tool("r2t0", "compose", after: ["r2"], input: { "script" => W::SCRIPTS["O7"] })], [])
    end

    # The nodes a call placed, drawn under it and nothing else.
    def placed(script, nodes)
      graph = D.graph(
        [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), *nodes,
         D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
        [%w[r1 r1t0], %w[r1t0 r2], *nodes.map { |node| [node["expansion_parent"], node["key"]] }]
      )
      D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => script })], [])
    end

    # The script's first tool, placed and completed under the call, beside the stage nodes drawn.
    def staged(script, stages)
      graph = D.graph(
        [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), n("r1t0-tool-1", "tool_task"), *stages,
         D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
        [%w[r1 r1t0], %w[r1t0 r1t0-tool-1], %w[r1t0-tool-1 r1t0-script-1], %w[r1t0 r2]]
      )
      D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => script })], [])
    end

    def fixture_trace(fixture)
      call = fixture.fetch("call")
      round = fixture.fetch("graph").fetch("nodes").find { |node| node["key"] == call }.fetch("expansion_parent")
      D.trace(fixture.fetch("graph"),
        [D.tool(call, "compose", after: [round], input: { "script" => fixture.fetch("script"), "params" => fixture["params"] }.compact)], [])
    end
end
