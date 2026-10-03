require_relative "executed_plan_scenarios"
require_relative "compose_bench_harness"
require "support/compose_bench/rehearsal"
require "support/task_bench/declared_set"

# THE REHEARSED READING: every valid first script judged on the plan the kernel would place, run in
# its objective's declared world — a result-reading stage run through the kernel's own evaluator over
# the envelopes its `results:` would carry, what it does drawn in the graph route's shape and scored by
# the executed reading. A verdict counts only where every world agrees; the stage-fed credit is
# printed beside the uncredited verdict, never in its place. Every existing record key is untouched.
class ComposeBenchRehearsalHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Worlds = E2E::ComposeBench::Worlds
  Rehearsal = E2E::ComposeBench::Rehearsal
  Executed = E2E::ComposeBench::Executed
  Scoring = E2E::ComposeBench::Scoring
  PLANS = ExecutedPlanScenarios.all.freeze
  # The runner tool contract these authored plans use.
  DECLARED = E2E::TaskBench::DeclaredSet.names(style: "nexus").freeze
  # The variant spelling the runner rho is: the file a grep names by its basename, and every
  # non-zero exit carried in the envelope.
  RUNNER = %w[matched_path runner_detail].freeze

  # A value stage reads the winning envelope and its one selected race arm.
  RACE_VALUE = <<~'JS'.freeze
    const race = g.parallel(["alpha", "bravo", "charlie"].map(host =>
      g.tool({ name: "probe_host", input: { host } })), { until: "any" });
    g.script({ results: [race], script: "return { winner_output: results[0].output, selected: results[0].selected };" });
  JS

  def test_a_stage_reading_the_race_is_a_value_where_o3_has_its_winner
    rehearsed = rehearse("O3", RACE_VALUE)
    value = rehearsed.run.returned.fetch("script-1")
    assert_equal "bravo: 200 OK (2s)", value["winner_output"]
    assert_equal 1, value["selected"].length
    read = reading("O3", RACE_VALUE)
    assert read["first_time_right"], read.inspect
    assert_equal "value", read.dig("stages", "script-1")
    assert_equal 1, read["worlds"]
    refute read["world_dependent"]
  end

  # A STAGE THAT READS RESULTS AND PLACES THE WRONG FOLLOW-UP SCORES WRONG: two models where the picture
  # has one step. A stage names only its own steps (`new Function(g, params, results)`), so the models
  # it places are the whole follow-up.
  def test_a_stage_placing_the_wrong_follow_up_scores_wrong
    o3 = reading("O3", <<~'JS')
      const race = g.parallel(["alpha", "bravo", "charlie"].map(h => g.tool({ name: "probe_host", input: { host: h } })), { until: "any" });
      g.script({ results: [race], script: "g.model({ prompt: 'Name the winner: ' + results[0].output }); g.model({ prompt: 'Say it again.' });" });
    JS
    refute o3["first_time_right"]
    assert_includes o3["silent"], "extra_steps"
    assert_equal "expanded", o3.dig("stages", "script-1")
    o7 = reading("O7", <<~'JS')
      const pairs = ["a", "b", "c"].map(h => {
        const fetch = g.tool({ name: "bash", input: { command: "curl -s https://" + h + ".example/feed" } });
        return [fetch, g.model({ prompt: "Normalise source " + h + ".", results: [fetch] })];
      });
      g.parallel(pairs);
      g.script({ results: pairs.map(p => p[1]), script: "g.model({ prompt: 'Merge: ' + results.length }); g.model({ prompt: 'Merge again.' });" });
    JS
    refute o7["first_time_right"]
    assert_includes o7["silent"], "extra_steps"
  end

  # A STAGE THAT THROWS PLACES NOTHING: O3's winner throws, so the plan misses its winner; O2's verify
  # stage throws after the edit it follows, and the plan is still O2's — the failure recorded.
  def test_a_throwing_stage_is_a_recorded_failure_contracted_out_of_the_plan
    o3 = reading("O3", <<~'JS')
      const race = g.parallel(["alpha", "bravo", "charlie"].map(h => g.tool({ name: "probe_host", input: { host: h } })), { until: "any" });
      g.script({ results: [race], script: "throw new Error('no winner: ' + results[0].output);" });
    JS
    assert_equal "failed script_error", o3.dig("stages", "script-1")
    refute o3["first_time_right"]
    assert_includes o3["silent"], "missing_steps"
    o2 = reading("O2", <<~'JS')
      const files = ["app/models/user.rb", "app/models/account.rb", "app/models/team.rb"];
      const greps = files.map(f => g.tool({ name: "grep", input: { pattern: "def full_name", path: f } }));
      g.parallel(greps);
      g.script({ results: greps, params: { files }, script: `
        const file = params.files.find((f, i) => results[i].output.includes("def full_name"));
        const edit = g.tool({ name: "edit", input: { path: file, old_text: "def full_name", new_text: "def display_name" } });
        g.script({ results: [edit], script: "throw new Error('verify: ' + results[0].output);" });
      ` });
    JS
    assert_equal({ "script-1" => "expanded", "script-1/script-1" => "failed script_error" }, o2["stages"])
    assert o2["first_time_right"], o2.inspect
    assert_equal ["app/models/team.rb"], o2["edited"]
  end

  # THE WORLD KEEPS WHAT THE PLAN DID: the verify grep after the edit reads the renamed line, in every
  # world the draw touched, and the draw is exact in each.
  def test_a_verify_grep_after_the_edit_reads_the_edited_file
    script = <<~'JS'
      const files = ["app/models/user.rb", "app/models/account.rb", "app/models/team.rb"];
      const greps = files.map(f => g.tool({ name: "grep", input: { pattern: "def full_name", path: f } }));
      g.parallel(greps);
      g.script({ results: greps, params: { files }, script: `
        const file = params.files.find((f, i) => results[i].output.includes("def full_name"));
        const edit = g.tool({ name: "edit", input: { path: file, old_text: "def full_name", new_text: "def display_name" } });
        const verify = g.tool({ name: "grep", input: { pattern: "def display_name", path: file }, after: [edit] });
        g.script({ results: [edit, verify], script: "return { edited: !results[0].is_error, verified: results[1].output };" });
      ` });
    JS
    rehearsed = rehearse("O2", script)
    assert_match(%r{\Aapp/models/team\.rb:5:   def display_name}, rehearsed.run.envelope("script-1/tool-2")["output"])
    read = reading("O2", script)
    assert_equal %w[matched_path no_match runner_detail], read["touched"]
    assert_equal 8, read["worlds"]
    assert read["first_time_right"], read.inspect
    refute read["world_dependent"]
  end

  # A VERDICT THE WORLD DECIDES IS NOT A VERDICT: a merge that parses its normalisers' text as JSON is
  # a value when the record format is JSON and throws when it is a sentence — world-dependent, not
  # right only in some world. A guarded parse can return a value in both worlds.
  def test_a_verdict_that_depends_on_the_world_counts_not_right
    pairs = <<~'JS'
      const pairs = ["a", "b", "c"].map(h => {
        const fetch = g.tool({ name: "bash", input: { command: "curl -s https://" + h + ".example/feed" } });
        return [fetch, g.model({ prompt: "Normalise source " + h + " into our record format.", results: [fetch] })];
      });
      g.parallel(pairs);
    JS
    read = reading("O7", "#{pairs}g.script({ results: pairs.map(p => p[1]), script: \"return results.flatMap(r => JSON.parse(r.output));\" });")
    assert_equal %w[record_format], read["touched"]
    assert read["world_dependent"]
    refute read["first_time_right"]
    assert read["liberal"]
    guarded = reading("O7", "#{pairs}g.script({ results: pairs.map(p => p[1]), script: \"return results.map(r => { try { return JSON.parse(r.output); } catch (e) { return null; } });\" });")
    refute guarded["world_dependent"]
    assert guarded["first_time_right"], guarded.inspect
  end

  # A STAGE THAT PLACES ITSELF AGAIN stops where the kernel stops it: O4's check re-lints after the
  # fix and re-places itself while the lint is dirty. Without the fix's effect it recurses to the
  # kernel's depth bound and fails there; with it the re-lint is clean and the check returns a value.
  # Both are extensions of the fix, exact in either world; nothing raises.
  def test_a_recursing_check_stops_at_the_kernels_depth_and_reads_exact_in_both_worlds
    script = <<~'JS'
      const check = "if (results[0].output.includes('no offenses')) return 'clean'; const lint = g.tool({ name: 'bash', input: { command: 'bin/rubocop app' } }); g.script({ results: [lint], params, script: params.check });";
      const suite = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const fix = g.model({ prompt: "Fix every offence the lint output names.", results: [lint] });
      const relint = g.tool({ name: "bash", input: { command: "bin/rubocop app" }, after: [fix] });
      g.parallel([suite, [lint, fix, relint, g.script({ results: [relint], params: { check }, script: check })]]);
    JS
    none = rehearse("O4", script)
    depth = AgentLoops::Scripts::Run::MAX_STAGE_DEPTH
    deepest = (["script-1"] * (depth + 1)).join("/")
    assert_equal "failed script_depth_exceeded", none.run.stages.fetch(deepest)
    assert_equal depth + 1, none.run.stages.length
    done = rehearse("O4", script, variant: %w[model_effect])
    assert_equal({ "script-1" => "value" }, done.run.stages)
    read = reading("O4", script)
    assert_equal %w[model_effect], read["touched"]
    assert read["first_time_right"], read.inspect
    refute read["world_dependent"]
  end

  # THE HARNESS'S OWN WALL: past 32 stage runs a stage is cut, never run, and every step downstream of
  # it is waiting — the kernel would not have reached them either.
  def test_past_the_wall_a_stage_is_cut_and_its_downstream_waits
    script = <<~'JS'
      const fan = "if (params.depth === 0) return params.depth; for (let i = 0; i < 3; i++) g.script({ params: { depth: params.depth - 1, fan: params.fan }, script: params.fan }); g.model({ prompt: 'join' });";
      const outer = g.script({ params: { depth: 3, fan }, script: fan });
      g.model({ prompt: "After the fan.", results: [outer] });
    JS
    rehearsed = rehearse("O1", script)
    assert_equal Worlds::WALL, rehearsed.run.stages.values.count { |outcome| outcome != "cut" }
    assert rehearsed.run.stages.values.include?("cut")
    statuses = rehearsed.drawing.graph.fetch("nodes").to_h { |node| [node["key"], node["status"]] }
    assert_equal "waiting", statuses.fetch("model-1"), "the step after the fan waits on what was cut"
  end

  # A value stage behind each probe tags its host; the final stage reads the selected tag.
  # The drawing preserves ownership and contracts only consumed value stages.
  TAGGED_RACE = <<~'JS'.freeze
    const race = g.parallel(params.hosts.map(host => {
      const probe = g.tool({ name: "probe_host", input: { host } });
      const tag = g.script({ params: { host }, results: [probe],
        script: "return { host: params.host, status: results[0].output };" });
      return [probe, tag];
    }), { until: "any" });
    g.script({ results: [race], script: "const winner = results[0].structured_content; return { winner: winner.host, status: winner.status };" });
  JS

  def test_the_drawing_is_the_routes_shape
    params = { "hosts" => %w[alpha bravo charlie] }
    rehearsed = rehearse("O3", TAGGED_RACE, params: params)
    graph = rehearsed.drawing.graph
    assert E2E::Gallery.marked?(graph)
    assert_equal({ "winner" => "bravo", "status" => "bravo: 200 OK (2s)" }, rehearsed.run.returned.fetch("script-4"))
    assert_equal %w[script-2], rehearsed.plan.transparent
    assert reading("O3", TAGGED_RACE, params: params)["first_time_right"]

    wrapper = rehearse("O4", <<~'JS')
      g.script({ script: "g.tool({ name: 'bash', input: { command: 'bin/rubocop app' } });" });
      g.model({ prompt: "Fix every offence the lint output names." });
    JS
    assert wrapper.plan.expanded?("script-1")
    Executed.lower(wrapper.plan)
    arm = rehearse("O3", <<~'JS')
      g.parallel([
        [g.tool({ name: "probe_host", input: { host: "bravo" } }), g.script({ script: "g.model({ prompt: 'bravo answered' });" })],
        g.tool({ name: "probe_host", input: { host: "alpha" } }),
      ], { until: "any" });
      g.model({ prompt: "Say which host won." });
    JS
    lowered = Executed.lower(arm.plan)
    join = lowered.nodes.find { |node| node.kind == "join" }.key
    assert_includes lowered.edges.select { |_, to| to == join }.map(&:first), "script-1/model-1",
      "a race arm ending in an expanding stage has its tail as the join's exit"
  end

  # Rehearsal must produce the independently authored route graph in the runner's world.
  # The path-sensitive stage fails when grep reports a basename. The unsupported perl edit
  # also makes its closing stage fail; neither failure is hidden by graph contraction.
  def test_the_drawing_matches_the_independently_authored_plan
    %w[stage_decided_edit stage_placed_model nested_stages per_source_value_stages value_stages_in_a_race whole_plan_wrapper
       wrapped_rendezvous failed_stage].each do |name|
      fixture = PLANS.fetch(name)
      rehearsed = rehearse(objective_of(fixture), fixture["script"], params: fixture["params"] || {}, variant: RUNNER, tool_names: DECLARED)
      if name == "stage_decided_edit"
        assert_equal ["perl"], rehearsed.run.unknown.map { |command| command.split.first }
        closing = fixture["graph"]["nodes"].last.fetch("key")
        fixture = fixture.merge("graph" => fixture["graph"].merge(
          "nodes" => fixture["graph"]["nodes"].map { |node| node["key"] == closing ? node.merge("status" => "failed") : node }
        ))
      end
      assert Executed.same_graph?(Executed.lower(rehearsed.plan), Executed.lower(plan_of(fixture))), name
    end
    failed = PLANS.fetch("failed_stage")
    runner = rehearse("O2", failed["script"], variant: RUNNER, tool_names: DECLARED)
    assert_equal "failed script_error", runner.run.stages.fetch("script-1/script-1")
    as_passed = rehearse("O2", failed["script"], tool_names: DECLARED)
    assert_equal "expanded", as_passed.run.stages.fetch("script-1/script-1")
    read = reading("O2", failed["script"], tool_names: DECLARED)
    assert_includes read["touched"], "matched_path"
    assert read["world_dependent"]
  end

  # THE REHEARSAL ONLY ADDS: every existing key of the probe's reading is today's, on the canonical
  # scripts and on each as a whole-plan wrapper, and the inliner with no world is the inliner.
  def test_the_existing_readings_are_unchanged
    probe = E2E::ComposeBench::Probe.allocate
    CANONICAL.each do |id, canonical|
      objective = Objectives.find(id)
      [canonical, "g.script({ script: #{JSON.generate(canonical)} });"].each do |script|
        built = evaluate(script)
        scored = Scoring.score_built(objective, built, tool_names: Tools::NAMES)
        read = probe.send(:reading, objective, { script: script, params: {} }, built, scored)
        inlined = Shape.inline(built.steps, tool_names: Tools::NAMES)
        assert_equal inlined, Shape.inline(built.steps, tool_names: Tools::NAMES, world: nil)
        graph = Shape.lower(inlined.steps)
        today = { **probe.send(:usable, inlined, graph), **probe.send(:expanded, objective, inlined, graph),
                  "endpoints" => E2E::ComposeBench::Endpoints.read(built, script: script, expanded: inlined.steps) }
        assert_equal today, read.except("rehearsed"), id
        assert_equal read["rehearsed"].keys.sort, Rehearsal::KEYS.select { |key| read["rehearsed"].key?(key) }.sort
      end
    end
  end

  # A stage writes outputs into a model's prompt without naming model results. Only the
  # separate stage-fed reading may credit those inputs; the deciding verdict stays uncredited.
  STAGE_FED_REVIEWS = <<~'JS'.freeze
    const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
    const seed = g.tool({ name: "bash", input: { command: "bin/rails db:seed" } });
    g.parallel([migrate, seed]);
    const dump = g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" } });
    const review = "g.model({ prompt: 'Review these outputs: ' + JSON.stringify(results.map(r => r.output)) });";
    const migration = g.script({ results: [migrate, dump], script: review });
    const seeding = g.script({ results: [seed, dump], script: review });
    g.parallel([migration, seeding]);
    g.script({ results: [migration, seeding],
      script: "g.model({ prompt: 'Merge these reviews: ' + JSON.stringify(results.map(r => r.output)) });" });
  JS

  def test_the_uncredited_verdict_decides_and_the_credit_is_printed_beside
    rehearsed = rehearse("T5", STAGE_FED_REVIEWS)
    refute rehearsed.uncredited["first_time_right"]
    assert_includes rehearsed.uncredited["silent"], "blind_model"
    read = reading("T5", STAGE_FED_REVIEWS)
    refute read["first_time_right"]
    credited_models = read.fetch("stage_fed", {})
    assert read["credited_first_time_right"] == read["first_time_right"] || credited_models.any?,
      "the two policies part only where the tree credits a model its stage fed"
  end

  private

    def rehearse(id, script, params: {}, variant: Worlds::W0, tool_names: Tools::NAMES)
      objective = Objectives.find(id)
      built, scored = built_and_scored(objective, script, params, tool_names)
      Rehearsal.rehearse(objective, built, scored, tool_names: tool_names, variant: variant)
    end

    def reading(id, script, params: {}, tool_names: Tools::NAMES)
      objective = Objectives.find(id)
      built, scored = built_and_scored(objective, script, params, tool_names)
      Rehearsal.reading(objective, built, scored, tool_names: tool_names)
    end

    def built_and_scored(objective, script, params, tool_names)
      built = Nexus::Compose::Evaluator.call(script: script, params: params, tool_names: tool_names)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      scored = Scoring.score_built(objective, built, tool_names: tool_names)
      flunk "#{scored["refusal"]}: #{scored["detail"]}" unless scored["valid_first"]
      [built, scored]
    end

    def plan_of(fixture) = Executed.plan(fixture.fetch("graph"), fixture.fetch("call"))

    def objective_of(fixture) = fixture.fetch("objective")
end
