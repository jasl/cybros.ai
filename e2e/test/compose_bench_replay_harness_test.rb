require_relative "executed_plan_scenarios"
require_relative "compose_bench_harness"
require "fileutils"
require "support/screen/corpus"
require "support/task_bench/declared_set"

# THE TEXT BENCH'S KERNEL CHECK (`Replay`): every script the bench scores on the harness's lowering
# lowers to the graph the tree's own kernel places for it — `Compose::Lower` → `Tasks::Compile` from
# a compose call's branch tip, in a `bin/rails runner` on this tree's Nexus — or both refuse it
# alike; and a harness that drifted from its kernel is caught, never scored.
class ComposeBenchReplayHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Replay = E2E::ComposeBench::Replay
  # Synthetic map, loop, stage and parameter cases.
  SYNTHETIC = JSON.parse(File.read(File.expand_path("../support/fixtures/compose_scripts/grep_then_edit.json", __dir__),
    encoding: Encoding::UTF_8)).freeze
  # Beside the canonical scripts, the shapes a step's reads turn on: a step naming nothing after a
  # group, a nested race named by its outer race, `after:` beside `results:`, a result-reading stage.
  SHAPES = [
    <<~JS,
      const a = g.tool({ name: "bash", input: { command: "git diff" } });
      const b = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      g.parallel([a, b]);
      g.model({ prompt: "Summarise." });
      g.model({ prompt: "Review the diff.", results: [a], after: [b] });
    JS
    <<~JS,
      const outer = g.parallel([
        [g.parallel([g.tool({ name: "probe_host", input: { host: "a" } }), g.tool({ name: "probe_host", input: { host: "b" } })], { until: "any" })],
        g.tool({ name: "probe_host", input: { host: "c" } }),
      ], { until: "any" });
      g.model({ prompt: "Who won?", results: [outer] });
    JS
    <<~JS,
      const probe = g.tool({ name: "probe_host", input: { host: "a" } });
      const tag = g.script({ results: [probe], script: "return results[0].output;" });
      g.model({ prompt: "Report the tag.", results: [tag] });
    JS
  ].freeze

  def test_every_script_the_bench_scores_lowers_to_its_kernels_graph
    scripts = [*CANONICAL.values, *SECOND_CANONICAL.values, *SHAPES].map { |script| { "script" => script, "params" => {} } } +
      SYNTHETIC.values.map { |run| run.slice("script", "params") }
    result = Replay.call(scripts)
    assert_equal scripts.size, result.built, "every script builds"
    assert_equal scripts.size, result.compared, "and every one is compared as a graph, none as a refusal"
    assert result.agrees?, result.mismatches.map { |replay, index| "#{index}: #{replay.reason}" }.join("\n")
  end

  # A SCRIPT THE EVALUATOR REFUSES has nothing to compare; one both lowerings refuse — a tool the
  # round never declared, a key over the bound — agrees.
  def test_a_refusal_is_compared_by_its_code
    long = "abcdefghijabcdefghijabcdefghijabc"
    result = Replay.call([{ "script" => "g.model({ prompt: ", "params" => {} },
                          { "script" => 'g.tool({ name: "curl", input: {} });', "params" => {} },
                          { "script" => %(g.model({ key: "#{long}", prompt: "x" });), "params" => {} }])
    assert_equal [false, true, true], result.replays.map(&:built)
    assert result.agrees?, result.mismatches.inspect
    assert_equal 0, result.compared, "an agreement on refusals compares no graph"
    assert_equal({ "unknown_tool_name" => 1, "composed_key_too_long" => 1 }, result.refused_alike)
    assert_equal "built 2, compared 0, refused alike 2 #{result.refused_alike.inspect}, mismatches 0", result.summary
  end

  # A READ THE KERNEL HANDED ANY NODE IS COMPARED, and so is the order a step reads in: a kernel that
  # handed a tool a read the harness's rule never makes, or a model its results in another order
  # than it named them, disagrees with the harness — neither is dropped as a kind that reads
  # nothing, nor matched as a set. A tree registered unordered compares each step's reads as a set,
  # and still compares every read.
  def test_a_read_on_any_node_and_the_order_of_reads_are_compared
    harness = { "nodes" => [{ "key" => "a", "kind" => "tool", "race" => nil, "reads" => [] },
                            { "key" => "b", "kind" => "tool", "race" => nil, "reads" => [] },
                            { "key" => "m", "kind" => "model", "race" => nil, "reads" => %w[a b] }],
                "edges" => [%w[a b], %w[b m], %w[a m]] }
    kernel = ->(tool_reads, model_reads) do
      { "nodes" => [{ "key" => "a", "task_kind" => "tool_task", "race" => nil, "input_from" => [], "result_from" => [] },
                    { "key" => "b", "task_kind" => "tool_task", "race" => nil, "input_from" => tool_reads, "result_from" => [] },
                    { "key" => "m", "task_kind" => "model_task", "race" => nil, "input_from" => [], "result_from" => model_reads }],
        "edges" => [%w[a b], %w[b m], %w[a m]] }
    end
    line = ->(tool_reads, model_reads) { { "built" => true, "shape" => harness, "kernel" => kernel.(tool_reads, model_reads) } }

    assert Replay.compare(line.([], %w[a b])).agrees
    refute Replay.compare(line.(%w[a], %w[a b])).agrees, "the kernel handed a tool a read"
    refute Replay.compare(line.([], %w[b a])).agrees, "the kernel handed the model its results in another order"
    assert Replay.compare(line.([], %w[b a]), ordered: false).agrees, "unordered, a step's reads are a set"
    refute Replay.compare(line.(%w[a], %w[a b]), ordered: false).agrees, "unordered, a read the kernel handed a tool still counts"
  end

  # THE ORDER RULE IS THE CALLER'S, per tree (`Screen::ReplayGate` reads it off the definition): a
  # tree whose lowering hands a step its reads in another order than its kernel names them is a
  # mismatch under the default, `ordered: true`, and one graph under `ordered: false`.
  def test_the_order_rule_is_the_callers
    shape = File.read(File.expand_path("../support/compose_bench/shape.rb", __dir__), encoding: "UTF-8")
    rule = "reads = Shape.race_reads(@race_exits, Nexus::Compose::Reads.of(verb, results))"
    assert_includes shape, rule
    script = <<~JS
      const diff = g.tool({ name: "bash", input: { command: "git diff" } });
      const summary = g.model({ prompt: "Summarise the diff.", results: [diff] });
      g.model({ prompt: "Review the diff against its summary.", results: [diff, summary] });
    JS
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "e2e/support/compose_bench"))
      File.symlink(File.join(Replay::ROOT, "nexus"), File.join(root, "nexus"))
      File.write(File.join(root, "e2e/support/compose_bench/shape.rb"),
        shape.gsub(/^require_relative .*\n/, "").sub(rule, "#{rule}.reverse"), encoding: "UTF-8")
      scripts = [{ "script" => script, "params" => {} }]
      ordered = Replay.call(scripts, root: root)
      assert_equal [0], ordered.mismatches.map(&:last), "the review reads its two results in the other order"
      unordered = Replay.call(scripts, root: root, ordered: false)
      assert unordered.agrees?, unordered.mismatches.map { |replay, _| replay.reason }.join("\n")
      assert_equal 1, unordered.compared, "a graph is compared, not a refusal"
    end
  end

  # NUL in a stage's source is unstoreable even when the evaluator accepts the outer script.
  # Both lowerings must reject it before graph placement.
  def test_the_nul_scripts_are_refused_alike_by_the_harness_and_the_kernel
    group = E2E::Screen::Corpus.read("nul").sole
    result = Replay.call(group.scripts, tool_names: group.tool_names, declarations: group.declarations)
    assert_equal 2, result.built, "the evaluator builds both"
    assert result.agrees?, result.mismatches.map { |replay, index| "#{index}: #{replay.reason}" }.join("\n")
    assert_equal 0, result.compared
    assert_equal({ "invalid_script" => 2 }, result.refused_alike)
  end

  # Independently drawn route graphs must agree with the kernel's compiler on top-level reads.
  # A continuation represents its owning model; a stage's leaf represents the stage. Runtime
  # expansions have no static compile node of their own and are checked by the executed reader.
  def test_every_executed_fixture_reads_what_the_kernel_compiles_for_its_script
    fixtures = ExecutedPlanScenarios.all
    lines = Replay.lowered(fixtures.values.map { |fixture| { "script" => fixture["script"], "params" => fixture["params"] || {} } },
      tool_names: E2E::TaskBench::DeclaredSet.names(style: "nexus"),
      declarations: E2E::TaskBench::DeclaredSet.function_definitions)
    fixtures.zip(lines).each do |(name, fixture), line|
      kernel = line.fetch("kernel") { flunk("#{name}: the evaluator refused its script") }
      refute kernel.key?("refusal"), "#{name}: the kernel refused its script: #{kernel["refusal"]}"
      compiled = kernel.fetch("nodes").to_h { |node| [node.fetch("key"), node] }
      call = fixture.fetch("call")
      nodes = fixture.dig("graph", "nodes").to_h { |node| [node.fetch("key"), node] }
      placement = lambda do |key|
        key = nodes.dig(key, "expansion_parent") until nodes.dig(key, "expansion_parent") == call
        key.delete_prefix("#{call}-")
      end
      nodes.each_value.select { |node| node["expansion_parent"] == call }.each do |node|
        own = node.fetch("key").delete_prefix("#{call}-")
        assert_empty Array(node["input_from"]), "#{name}: #{own} reads by position"
        assert_equal compiled.fetch(own).fetch("result_from"), Array(node["result_from"]).map(&placement).uniq, "#{name}: #{own}"
      end
    end
  end

  # A HARNESS THAT DRIFTED IS CAUGHT: the same tree's kernel beside a lowering that hands a model
  # step what it waits on — the positional read the kernel no longer makes — disagrees on the flat
  # peers spelling of O7b, whose report waits on every member and names two, and says how.
  def test_a_lowering_that_reads_by_position_is_caught_against_the_kernel
    shape = File.read(File.expand_path("../support/compose_bench/shape.rb", __dir__), encoding: "UTF-8")
    rule = "reads = Shape.race_reads(@race_exits, Nexus::Compose::Reads.of(verb, results))"
    assert_includes shape, rule
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "e2e/support/compose_bench"))
      File.symlink(File.join(Replay::ROOT, "nexus"), File.join(root, "nexus"))
      File.write(File.join(root, "e2e/support/compose_bench/shape.rb"),
        shape.gsub(/^require_relative .*\n/, "").sub(rule, %(#{rule} | (verb == "model" ? cursor.waits : []))), encoding: "UTF-8")
      result = Replay.call([{ "script" => SECOND_CANONICAL.fetch("O7b"), "params" => {} }, { "script" => CANONICAL.fetch("O1"), "params" => {} }],
        root: root)
      assert_equal [0], result.mismatches.map(&:last), "O1's verdict names every review it waits on, so only O7b's report drifts"
      assert_match(/\Athe harness lowers .* where the kernel placed /, result.mismatches.sole.first.reason)
    end
  end
end
