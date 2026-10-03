require_relative "compose_bench_harness"

# THE LOWERING: the harness's copy of the kernel's cursor rule waits by written order and reads by
# name alone, as the kernel's `Nexus::Compose::Reads` says — a group, a race, `after:` and
# `results:`, a stage and a detached subgraph each placed as `Tasks::Compile` places them. The
# pictures scored on this lowering are `compose_bench_pictures_harness_test.rb`'s.
class ComposeBenchLoweringHarnessTest < Minitest::Test
  include ComposeBenchHarness

  # WRITTEN ORDER IS THE WAITS, NAMES ARE THE READS: a group hands the step after it its exits —
  # each sequence's final wait — and nothing to read; a nested model after its own tool reads it
  # only by naming it; and naming hands a step exactly those results, in the order named.
  def test_the_lowering_waits_by_written_order_and_reads_by_name
    script = <<~JS
      const a1 = g.tool({ name: "bash", input: { command: "a" } });
      const b1 = g.model({ prompt: "read a" });
      const b2 = g.model({ prompt: "b2" });
      const a2 = g.tool({ name: "bash", input: { command: "a2" } });
      const a3 = g.tool({ name: "bash", input: { command: "a3" } });
      const a4 = g.tool({ name: "bash", input: { command: "a4" } });
      g.parallel([[a1, b1], [b2, a2], [a3, a4]]);
      g.model({ prompt: "after" });
    JS
    graph = lower(script)
    assert_equal %w[model-1 tool-2 tool-4], graph.edges.select { |_, to| to == "model-3" }.map(&:first).sort,
      "the group's exits: each sequence's final wait"
    assert_equal [["tool-1", "model-1"], ["model-2", "tool-2"], ["tool-3", "tool-4"]],
      graph.edges.reject { |_, to| to == "model-3" }
    assert_equal({ "model-1" => [], "model-2" => [], "model-3" => [] }, graph.reads,
      "a step that names nothing reads its prompt alone, whatever ran before it")
    refute graph.nodes.any?(&:detached), "no step carries a WHEN word"

    named = lower(script.sub('{ prompt: "read a" }', '{ prompt: "read a", results: [a1] }')
      .sub('{ prompt: "after" }', '{ prompt: "after", results: [a4, b1, a2] }'))
    assert_equal({ "model-1" => %w[tool-1], "model-2" => [], "model-3" => %w[tool-4 model-1 tool-2] }, named.reads,
      "a named step reads exactly what it names, in that order")
    assert_equal graph.edges.sort, named.edges.sort, "names restate waits the group already makes"
  end

  # THE READ RULE IS THE KERNEL'S, CALLED AND NEVER RESTATED: on every verb the kernel compiles, a
  # leaf written after a tool and naming another reads what `Nexus::Compose::Reads.of` says it reads
  # of its names — a model or a script its `results:`, a tool, an ask or a wait nothing — and never
  # the tool before it. The step trees are the door's, which a builder never writes for a verb
  # without `results`, so the rule is read where it is not also a builder refusal.
  def test_the_harness_reads_are_the_kernels_read_rule
    (Nexus::Compose::Grammar::VERBS - ["parallel"]).each do |verb|
      steps = [{ "tool" => { "key" => "tool-1", "name" => "bash" } }, { "tool" => { "key" => "tool-2", "name" => "bash" } },
               { verb => { "key" => "step", "results" => %w[tool-1] } }]
      assert_equal Nexus::Compose::Reads.of(verb, %w[tool-1]), Shape.lower(steps).node("step").reads, verb
    end
  end

  # ALL SIX VERBS THE KERNEL COMPILES: `wait` and `script` are leaves like a tool — each becomes
  # what the next step waits on — and `after:` and `results:` add a wait edge from every key they
  # name (`@extra_waits`); a model reads what it names, a script's output among them.
  def test_wait_and_script_are_leaves_and_after_and_results_wire_their_edges
    graph = lower(<<~JS)
      const a = g.tool({ name: "bash", input: { command: "a" } });
      g.tool({ name: "bash", input: { command: "b" } });
      const s = g.script({ script: "return 1", results: [a] });
      g.wait({ task: "r1t0", after: [a] });
      g.model({ prompt: "read", results: [s] });
    JS
    assert_equal %w[tool tool script wait model], graph.nodes.map(&:kind)
    assert_equal [%w[script-1 model-1], %w[script-1 wait-1], %w[tool-1 script-1], %w[tool-1 tool-2], %w[tool-1 wait-1],
                  %w[tool-2 script-1], %w[wait-1 model-1]], graph.edges.sort
    assert_equal %w[script-1], graph.node("model-1").reads, "what it names, never what came before it"
    assert_equal %w[tool-1], graph.node("script-1").reads

    fanned = lower(<<~JS)
      g.parallel([
        g.tool({ name: "bash", input: { command: "suite" } }),
        [g.tool({ name: "bash", input: { command: "scan" } }), g.script({ script: "return results[0]" })],
      ]);
      g.model({ prompt: "report" });
    JS
    assert_equal [%w[script-1 model-1], %w[tool-1 model-1], %w[tool-2 script-1]], fanned.edges.sort
    assert_empty fanned.node("model-1").reads, "a group hands the step after it nothing to read"

    # A flat parallel can express dependencies through `results:` alone.
    wired = lower(<<~JS)
      const suite = g.tool({ name: "bash", input: { command: "suite" } });
      const lint = g.tool({ name: "bash", input: { command: "lint" } });
      g.parallel([suite, lint, g.model({ prompt: "fix", results: [lint] })]);
    JS
    assert_equal [%w[tool-2 model-1]], wired.edges
    assert_equal %w[tool-2], wired.node("model-1").reads, "the fix reads the lint alone"
    assert_equal Nexus::Compose::Grammar::VERBS.sort, Shape::VERBS.sort, "the restatement knows every verb the kernel compiles"
  end

  # A RACE PLACES A JOIN, AND A STEP READS IT ONLY BY NAME: the step after it waits on the join; one
  # naming nothing reads nothing, one naming the race reads the members its selection is drawn from.
  def test_a_race_places_a_join_and_a_follower_reads_the_members_only_by_naming_the_race
    script = <<~JS
      const race = g.parallel([g.tool({ name: "probe_host", input: { host: "a" } }), g.tool({ name: "probe_host", input: { host: "b" } })], { until: "any" });
      g.model({ prompt: "who won" });
    JS
    graph = lower(script)
    join = graph.nodes.find { |node| node.kind == "join" }
    assert_equal "any", join.race
    assert_equal [["tool-1", "parallel-1"], ["tool-2", "parallel-1"], ["parallel-1", "model-1"]], graph.edges
    assert_empty graph.node("model-1").reads
    named = lower(script.sub('{ prompt: "who won" }', '{ prompt: "who won", results: [race] }'))
    assert_equal %w[tool-1 tool-2], named.node("model-1").reads
    assert_equal graph.edges, named.edges, "naming the race waits on its join alone"
  end

  # A DETACHED COMPOSE'S STEPS WIRE INSIDE IT: the WHEN word is on the call, so `Shape` reads
  # detachment off the cursor — every node of a detached script is detached and the wiring is the
  # same as attached.
  def test_a_detached_composes_steps_wire_inside_it_and_shape_reads_the_cursor
    script = <<~JS
      const grep = g.tool({ name: "grep", input: { pattern: "x", path: "a" } });
      const aside = g.model({ prompt: "aside", results: [grep] });
      g.model({ prompt: "main", results: [aside] });
    JS
    attached = lower(script)
    detached = Shape.lower(evaluate(script).steps, detached: true)
    [attached, detached].each do |graph|
      assert_equal ["tool-1"], graph.node("model-1").reads
      assert_equal ["model-1"], graph.node("model-2").reads
      assert_equal [["tool-1", "model-1"], ["model-1", "model-2"]], graph.edges
    end
    refute attached.nodes.any?(&:detached)
    assert detached.nodes.all?(&:detached), "the cursor's detachment reaches every node"
    assert_empty detached.reads, "a detached model step is no foreground reader for the picture"
  end
end
