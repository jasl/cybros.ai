require_relative "compose_bench_harness"
require_relative "../../nexus/app/services/agent_loops/branch_tools"
require_relative "../../nexus/app/services/agent_loops/compose/lower"

# THE STAGE INLINER: a result-free `g.script` stage is replaced by the expansion the SHIPPED
# evaluator builds for it, contracted the way the kernel splices it — the expansion's roots wait on
# what the stage waited on, its steps read only what they name among one another, and whatever
# named the stage follows the expansion's final leaf. A stage that reads results, returns a value
# or is refused stays a stage leaf and is reported.
class ComposeBenchInlineHarnessTest < Minitest::Test
  include ComposeBenchHarness

  # A WHOLE-PLAN WRAPPER is the plan it wraps: each canonical script, placed as one result-free
  # stage, inlines to a graph its objective's picture scores exact. The two canonical scripts that
  # end on a group are no stage body — the evaluator refuses them — and stay a stage leaf.
  def test_a_whole_plan_wrapper_inlines_to_the_plan_it_wraps
    CANONICAL.each do |id, script|
      inlined = inline("g.script({ script: #{JSON.generate(script)} });")
      if %w[O4 T5].include?(id)
        assert_equal ["script-1"], inlined.refused.map(&:key), id
        assert_equal "script_error", inlined.refused.sole.refusal
        assert_match(/must end with ONE step/, inlined.refused.sole.detail)
        assert_equal %w[script], Shape.lower(inlined.steps).nodes.map(&:kind), "#{id}: a refused stage stays a leaf"
      else
        assert_equal ["script-1"], inlined.inlined, id
        score = Objectives.find(id).picture.score(Shape.lower(inlined.steps))
        assert score["exact_edges"] && score["exact_reads"], "#{id}: #{score.inspect}"
      end
    end
  end

  # The whole race is inside one result-free stage. The static
  # reading sees a single script node; the inlined one has O3's waits, and its winner — naming
  # nothing — reads its prompt alone; the same wrapper naming its race is O3's picture.
  RACE_WRAPPER = <<~'JS'.freeze
    g.script({
      script: `
        g.parallel([
          g.tool({ name: "bash", input: { command: "bin/probe alpha" } }),
          g.tool({ name: "bash", input: { command: "bin/probe bravo" } }),
          g.tool({ name: "bash", input: { command: "bin/probe charlie" } }),
        ], { until: "any" });
        g.model({
          tools: [],
          prompt: "Name the winning host."
        });
      `
    })
  JS

  def test_a_race_wrapper_inlines_to_an_exact_race
    picture = Objectives.find("O3").picture
    refute picture.score(lower(RACE_WRAPPER))["exact_edges"], "statically one stage stands for the race"
    inlined = inline(RACE_WRAPPER)
    assert_equal ["script-1"], inlined.inlined
    assert_empty inlined.opaque
    graph = Shape.lower(inlined.steps)
    assert_equal %w[script-1/tool-1 script-1/tool-2 script-1/tool-3 script-1/parallel-1 script-1/model-1], graph.keys,
      "a race the stage placed is the stage's own, keyed under it like its leaves"
    assert_equal({ "exact_edges" => true, "exact_reads" => false, "silent" => ["blind_model"] }, picture.score(graph))
    named = RACE_WRAPPER.sub("g.parallel([", "const race = g.parallel([").sub("tools: [],", "tools: [], results: [race],")
    score = picture.score(Shape.lower(inline(named).steps))
    assert score["exact_edges"] && score["exact_reads"], score.inspect
  end

  # THE CONTRACTION: the stage's own wait (the lint before it) and its `after:` become the waits
  # of the expansion's root; the expansion's model reads the tool it names and nothing placed
  # before the stage; the step after the stage waits on the expansion's final leaf and, naming the
  # stage, reads that leaf alone. The keys an expansion places are namespaced under the stage, so
  # the inner `model-1` never meets the outer one.
  def test_an_expansion_waits_on_what_the_stage_waited_on_and_reads_nothing_before_it
    inlined = inline(<<~'JS')
      const setup = g.tool({ name: "bash", input: { command: "bin/setup" } });
      g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const s = g.script({ after: [setup], script: 'const run = g.tool({ name: "bash", input: { command: "bin/rails test" } }); g.model({ prompt: "Summarise the failures.", results: [run] });' });
      g.model({ prompt: "Report.", results: [s] });
    JS
    graph = Shape.lower(inlined.steps)
    assert_equal %w[tool-1 tool-2 script-1/tool-1 script-1/model-1 model-1], graph.keys
    assert_equal [%w[script-1/model-1 model-1], %w[script-1/tool-1 script-1/model-1], %w[tool-1 script-1/tool-1],
                  %w[tool-1 tool-2], %w[tool-2 script-1/tool-1]], graph.edges.sort
    assert_equal %w[script-1/tool-1], graph.node("script-1/model-1").reads, "the expansion reads nothing of the plan around it"
    assert_equal %w[script-1/model-1], graph.node("model-1").reads, "the reader reads the final leaf in the stage's place"
  end

  # AS A GROUP MEMBER an expansion is one member: its final leaf is the member's exit, and a step
  # after the group naming the stage reads that leaf.
  def test_an_expansion_inside_a_group_is_that_members_chain
    inlined = inline(<<~'JS')
      const fix = g.script({ script: 'const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } }); g.model({ prompt: "Fix every offence.", results: [lint] });' });
      g.parallel([g.tool({ name: "bash", input: { command: "bin/rails test" } }), fix]);
      g.model({ prompt: "Report.", results: [fix] });
    JS
    graph = Shape.lower(inlined.steps)
    assert_equal [%w[script-1/model-1 model-1], %w[script-1/tool-1 script-1/model-1], %w[tool-1 model-1]], graph.edges.sort
    assert_equal %w[script-1/model-1], graph.node("model-1").reads
  end

  # WHAT STAYS A LEAF: a stage that reads results is opaque — its body depends on output no text
  # can know; one that returns a value places nothing; one the evaluator refuses, or whose
  # expansion names a tool the round never declared (the kernel's stage lowering refuses it at run
  # time), fails as a stage. Each is reported under its key and none moves a reference.
  def test_a_stage_that_reads_returns_or_is_refused_stays_a_leaf
    inlined = inline(<<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: "return results[0].output;" });
      g.script({ script: "return 42;" });
      g.script({ script: 'g.tool({ name: "curl", input: { url: "https://a.example" } }); g.model({ prompt: "x" });' });
      g.script({ script: 'g.model({ prompt: "x" ' });
      g.model({ prompt: "Report." });
    JS
    assert_empty inlined.inlined
    assert_equal ["script-1"], inlined.opaque
    assert_equal ["script-2"], inlined.valued
    assert_equal [%w[script-3 unknown_tool_name], %w[script-4 script_syntax_error]], inlined.refused.map { |r| [r.key, r.refusal] }
    assert_match(/"curl" is not one of your tools/, inlined.refused.first.detail)
    assert_equal lower(<<~'JS').edges, Shape.lower(inlined.steps).edges, "the leaves lower as the static reading does"
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: "return results[0].output;" });
      g.script({ script: "return 42;" });
      g.script({ script: 'g.tool({ name: "curl", input: { url: "https://a.example" } }); g.model({ prompt: "x" });' });
      g.script({ script: 'g.model({ prompt: "x" ' });
      g.model({ prompt: "Report." });
    JS
  end

  # A STAGE THAT READS RESULTS IS REFUSED ONLY WHEN ITS SOURCE DOES NOT PARSE: no result can
  # change a parse failure, so the kernel fails that stage whatever the plan produces. Any other
  # failure on no results — a property of a missing envelope, or JSON.parse on output that is not
  # there, which the kernel calls a script error and not a syntax error — is the empty list's, and
  # the stage stays opaque.
  def test_a_stage_that_reads_results_is_refused_only_when_its_source_does_not_parse
    inlined = inline(<<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: "return results[0].output +;" });
      g.script({ results: [probe], script: "const r = results[0]; return JSON.parse(r ? r.output : '{');" });
      g.script({ results: [probe], script: "return results[0].output.trim();" });
      g.model({ prompt: "Report." });
    JS
    assert_equal [%w[script-1 script_syntax_error]], inlined.refused.map { |refused| [refused.key, refused.refusal] }
    assert_match(/at line 1 of the g\.script stage's script/, inlined.refused.sole.detail)
    assert_equal %w[script-2 script-3], inlined.opaque
    assert_empty inlined.inlined
  end

  # A STAGE THAT PLACES STEPS WHATEVER IT READS: its run over no results builds steps the kernel's
  # stage lowering accepts. Each stage the inliner expands is one, and so is a result-reading stage
  # whose body places a step before it reads anything; a stage that returns a value, fails on the
  # empty list, or is refused — its source, or the steps it built — is not. A stage that places
  # steps only on real data returns a value here, so only the plan that ran shows what it placed.
  # The static picture reads this list: a placer never stands for a pictured step and never drops
  # out as the plan's answer.
  def test_a_stage_that_builds_steps_on_no_results_is_a_placer
    inlined = inline(<<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "alpha" } });
      g.script({ results: [probe], script: 'g.model({ prompt: "Read " + results.length + " results." });' });
      g.script({ results: [probe], script: "return results[0].output.trim();" });
      g.script({ results: [probe], script: 'if (results.length === 0) return null; g.model({ prompt: "x" });' });
      g.script({ results: [probe], script: 'g.model({ prompt: "x", tools: ["read"] });' });
      g.script({ script: 'g.model({ prompt: "x" });' });
      g.script({ script: 'g.tool({ name: "curl", input: { url: "https://a.example" } }); g.model({ prompt: "x" });' });
      g.script({ script: "return 42;" });
      g.script({ script: 'g.model({ prompt: "x" ' });
      g.model({ prompt: "Report." });
    JS
    assert_equal %w[script-1 script-5], inlined.placers
    assert_equal %w[script-1 script-2 script-3 script-4], inlined.opaque, "a result-reading placer is opaque too"
    assert_equal %w[script-5], inlined.inlined
  end

  # THE STAGE'S OWN LOWERING REFUSES WHAT THE EVALUATOR BUILDS: a `g.model` naming a tool the stage
  # does not inherit, a key over the kernel's bound (one at the bound inlines), and a graph verb —
  # a branch never inherits `compose` or `task`, in any spelling, even when the round declares
  # them. The kernel fails each such stage at run time and places nothing, so each stays a leaf,
  # reported in the kernel's own sentence.
  def test_a_stage_the_kernels_lowering_refuses_stays_a_leaf
    inlined = inline(<<~'JS', tool_names: [*Tools::NAMES, "compose", "task"])
      g.script({ script: 'g.model({ prompt: "x", tools: ["read"] });' });
      g.script({ script: 'g.model({ key: "abcdefghijabcdefghijabcdefghijabc", prompt: "x" });' });
      g.script({ script: 'g.tool({ name: "compose", input: {} }); g.model({ prompt: "x" });' });
      g.script({ script: 'g.tool({ name: "task", input: { prompt: "find it" } }); g.model({ prompt: "Report." });' });
      g.script({ script: 'g.model({ key: "abcdefghijabcdefghijabcdefghijab", prompt: "x" });' });
      g.model({ prompt: "Report." });
    JS
    have = "You have: read_file, grep, edit, bash, probe_host"
    assert_equal [
      ["script-1", "unknown_tool_name", %(g.model: "read" is not one of your tools. #{have})],
      ["script-2", "composed_key_too_long", "abcdefghijabcdefghijabcdefghijab… (max 32 characters)"],
      ["script-3", "unknown_tool_name", %(g.tool: "compose" is not one of your tools. #{have})],
      ["script-4", "unknown_tool_name", %(g.tool: "task" is not one of your tools. #{have})],
    ], inlined.refused.map { |refused| [refused.key, refused.refusal, refused.detail] }
    assert_equal ["script-5"], inlined.inlined, "a key at the bound is the kernel's to place"
    assert_equal %w[script-1 script-2 script-3 script-4 script-5/abcdefghijabcdefghijabcdefghijab model-1],
      Shape.lower(inlined.steps).keys

    claude = inline(%(g.script({ script: 'g.tool({ name: "Agent", input: { prompt: "find it" } }); g.model({ prompt: "x" });' });),
      tool_names: Styles.find("claude").names)
    assert_equal ["script-1"], claude.refused.map(&:key), "the preset's `Agent` is `task` spelled otherwise"
    assert_equal %(g.tool: "Agent" is not one of your tools. #{have}, AskUserQuestion), claude.refused.sole.detail
  end

  # THE STAGE'S APPEND REFUSES WHAT ITS LOWERING PASSED: a stage whose source the row store holds
  # can still build a step it cannot — here a tool input carrying U+0000 — and the kernel's compiler
  # refuses that expansion, so the stage fails and places nothing. It stays a leaf, reported under
  # the compiler's code; its readers still read the stage.
  def test_a_stage_whose_expansion_the_kernels_compiler_refuses_stays_a_leaf
    inlined = inline(<<~'JS')
      const s = g.script({ script: 'g.tool({ name: "grep", input: { pattern: String.fromCharCode(0), path: "a" } }); g.model({ prompt: "x" });' });
      g.model({ prompt: "Report.", results: [s] });
    JS
    assert_empty inlined.inlined
    assert_equal [%w[script-1 invalid_tool_input]], inlined.refused.map { |refused| [refused.key, refused.refusal] }
    graph = Shape.lower(inlined.steps)
    assert_equal %w[script-1 model-1], graph.keys
    assert_includes graph.node("model-1").reads, "script-1"
  end

  # THE RESTATED BOUNDS ARE THE KERNEL'S: `Lower`'s key bound, and every spelling the alias tables
  # give the graph verbs a branch never inherits — the kernel withholds them by canonical.
  def test_the_restated_bounds_are_the_kernels
    assert_equal AgentLoops::Compose::Lower::MAX_SCRIPT_KEY, Shape::MAX_SCRIPT_KEY
    presets = E2E::AdaptationRows.pack.presets
    spellings = AgentLoops::BranchTools::WITHHELD.flat_map do |canonical|
      aliases = presets.aliases_for(presets.words).select { |spec| spec.fetch("canonical") == canonical }
      [presets.plain_name(canonical), *aliases.map { |spec| spec.fetch("name") }]
    end
    assert_equal spellings.sort, Shape::WITHHELD.sort
  end

  # RECURSIVELY: a stage an expansion places is inlined in turn, under the namespace of the stage
  # that placed it. A result-free wrapper whose race is read by a
  # stage naming every probe — refused where the kernel's stage run refuses it, since a script's
  # race stops the members it did not select, so the wrapper is a stage the kernel fails.
  RACE_WRAPPED_READER = <<~'JS'.freeze
    g.script({
      script: `
        const hosts = ["alpha", "bravo", "charlie"];
        const probes = hosts.map(function(h) {
          return g.tool({ name: "bash", input: { command: "bin/probe " + h } });
        });
        g.parallel(probes, { until: "any" });
        g.script({
          results: probes,
          script: "return results[0].output;"
        });
      `
    });
  JS

  def test_a_stage_placed_by_a_stage_inlines_in_turn
    nested = inline(%(g.script({ script: #{JSON.generate(%(g.script({ script: 'g.model({ prompt: "x" });' });))} });))
    assert_equal %w[script-1 script-1/script-1], nested.inlined
    assert_equal %w[script-1/script-1/model-1], Shape.lower(nested.steps).keys

    wrapped = inline(RACE_WRAPPED_READER)
    assert_empty wrapped.inlined
    refused = wrapped.refused.sole
    assert_equal %w[script-1 script_error], [refused.key, refused.refusal]
    assert_includes refused.detail, %(results names "tool-1", a member of the race on line 6)
    assert_equal "race_member", E2E::ComposeBench::Buckets.loud(refused.refusal, refused.detail)
  end

  # The same wrapper naming the race itself: the inner reader's `results: [race]` is renamed with
  # the race's key under the stage, waits on the join alone and reads the probes the race selected
  # from — O3 exact, where naming the probes one by one read `over_sync`.
  def test_a_race_a_stage_placed_is_named_under_the_stage_and_read_through_its_exits
    wrapped = inline(<<~'JS')
      g.script({
        script: `
          const probes = ["alpha", "bravo", "charlie"].map(function(h) {
            return g.tool({ name: "bash", input: { command: "bin/probe " + h } });
          });
          const race = g.parallel(probes, { until: "any" });
          g.script({ results: [race], script: "const won = results[0]; if (won.status !== 'completed') throw new Error('none'); return won.output;" });
        `
      });
    JS
    assert_equal ["script-1"], wrapped.inlined
    assert_equal ["script-1/script-1"], wrapped.opaque
    reader = wrapped.steps.sole.fetch(Shape::EXPANSION).fetch("steps").last.fetch("script")
    assert_equal ["script-1/parallel-1"], reader.fetch("results")
    graph = Shape.lower(wrapped.steps)
    assert_equal %w[script-1/tool-1 script-1/tool-2 script-1/tool-3], graph.node("script-1/script-1").reads
    assert_equal [["script-1/parallel-1", "script-1/script-1"]], graph.edges.select { |_, to| to == "script-1/script-1" }
    score = Objectives.find("O3").picture.score(graph)
    assert score["exact_edges"] && score["exact_reads"], score.inspect
  end

  private

    def inline(script, tool_names: Tools::NAMES)
      built = evaluate(script)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      Shape.inline(built.steps, tool_names: tool_names)
    end
end
