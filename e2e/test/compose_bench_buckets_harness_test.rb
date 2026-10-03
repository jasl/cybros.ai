require_relative "compose_bench_harness"

# THE LOUD BUCKETS: every refusal sentence the shipped evaluator speaks lands in the bucket named
# for its defect, so failures group by error string first.
class ComposeBenchBucketsHarnessTest < Minitest::Test
  include ComposeBenchHarness

  def test_the_loud_buckets_read_the_shipped_sentences
    buckets = E2E::ComposeBench::Buckets
    assert_equal "unknown_option", buckets.loud(:script_error, refusal('g.tool({ name: "bash", command: "x" });'))
    assert_equal "edge_word", buckets.loud(:script_error, refusal('g.model({ prompt: "x", input_from: [] });'))
    assert_equal "handle_throw", buckets.loud(:script_error, refusal('const a = g.tool({ name: "bash" }); g.model({ prompt: "see " + a });'))
    # A method or a field a RESULT would have, called on the label: the
    # cross-model run's `other` bucket (a raw `TypeError`), loud now.
    assert_equal "handle_throw", buckets.loud(:script_error,
      refusal('const a = g.tool({ name: "bash" }); if (a.includes("x")) g.model({ prompt: "fix" });'))
    assert_equal "handle_throw", buckets.loud(:script_error, refusal('const a = g.tool({ name: "bash" }); g.model({ prompt: "p" + a.output });'))
    assert_equal "g_join", buckets.loud(:script_error, refusal("g.join([]);"))
    assert_equal "not_a_verb", buckets.loud(:script_error, refusal("g.race([]);"))
    assert_equal "is_not_defined", buckets.loud(:script_error, refusal("tool({ name: \"bash\" });"))
    assert_equal "one_object", buckets.loud(:script_error, refusal('g.tool({ name: "bash" }, { key: "k" });'))
    assert_equal "deleted_word", buckets.loud(:script_error, refusal('g.tool({ name: "bash", run_in_background: true });')),
      "the deleted per-step word is loud, answered with the call's wait"
    assert_equal "deleted_word", buckets.loud(:script_error, refusal('g.parallel([g.tool({ name: "bash" })], { wait: "any" });')),
      "the fan's old join word is loud, answered with until: and the call's home"
    assert_equal "group_in_group", buckets.loud(:script_error,
      refusal('const i = g.parallel([g.tool({ name: "bash" })]); g.parallel([i, g.tool({ name: "bash" })]);'))
    assert_equal "member_not_a_step", buckets.loud(:script_error, refusal('g.parallel(["bash"]);'))
    assert_equal "tool_name", buckets.loud("unknown_tool_name", 'g.tool: "read" is not one of your tools. You have: grep')
    # The evaluator's two whole-script refusals: a step placed after the script returned, and none.
    assert_equal "deferred", buckets.loud(:script_error,
      refusal('g.tool({ name: "bash" }); Promise.resolve().then(() => g.model({ prompt: "late" }));'))
    assert_equal "no_step", buckets.loud(:script_error, refusal("const unused = 1;"))
    assert_includes buckets.normalize('g.tool: unknown option "command". Tool arguments go under input'), 'unknown option "…"'
  end

  # THE KERNEL'S REPAIR SENTENCES, each in the bucket named for its defect: a step's own option
  # written inside a tool's input, a tool's `results:`, a group member that reads one listed after
  # it, and a stage that ends on a group. The regroup refusal stays a member mistake whichever cause
  # it names. A syntax refusal is keyed by the engine's message alone: its line, column and the
  # echoed source line never split a group.
  def test_the_repair_sentences_land_in_their_buckets_and_a_position_never_keys_a_group
    buckets = E2E::ComposeBench::Buckets
    assert_equal "after_in_input", buckets.loud(:script_error, refusal(<<~JS))
      const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
      g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump", after: [migrate] } });
    JS
    assert_equal "tool_reads", buckets.loud(:script_error,
      refusal('const m = g.tool({ name: "bash" }); g.tool({ name: "bash", input: { command: "x" }, results: [m] });')),
      "a tool's results: is not the deleted-word bucket"
    assert_equal "tool_reads", buckets.loud(:script_error,
      refusal('const m = g.tool({ name: "bash" }); g.tool({ name: "bash", input: { command: "x", results: [m] } });'))
    assert_equal "member_order", buckets.loud(:script_error, refusal(<<~JS))
      const source = g.tool({ name: "bash", input: { command: "git diff" } });
      const review = g.model({ prompt: "Review the patch.", results: [source] });
      g.parallel([review, source]);
    JS
    stage = Nexus::Compose::Evaluator.stage(script: 'g.parallel([g.tool({ name: "bash" }), g.tool({ name: "bash" })]);',
      tool_names: Tools::NAMES)
    assert_equal "stage_end", buckets.loud(stage.refusal, stage.detail)
    assert_equal "member_not_a_step", buckets.loud(:script_error, refusal(<<~JS)), "the chain at the tail"
      const probe = host => { g.tool({ name: "probe_host", input: { host } }); return g.script({ script: "return 1" }); };
      g.parallel(["a", "b"].map(probe));
    JS
    assert_equal "member_not_a_step", buckets.loud(:script_error, refusal(<<~JS)), "a step an earlier group took"
      const a = g.tool({ name: "bash" });
      g.parallel([a, g.tool({ name: "bash" })]);
      g.parallel([a, g.tool({ name: "bash" })]);
    JS

    race = 'const race = g.parallel([g.tool({ name: "bash" }), g.tool({ name: "bash" })], { until: "any" });'
    assert_equal "race_unwrapped", buckets.loud(:script_error, refusal("#{race} g.script({ results: race, script: \"return 1\" });")),
      "the race written as the list itself"
    assert_equal "race_member", buckets.loud(:script_error, refusal(<<~JS)), "a leaf of a formed race"
      const a = g.tool({ name: "bash" });
      g.parallel([a, g.tool({ name: "bash" })], { until: "any" });
      g.model({ prompt: "p", results: [a] });
    JS
    assert_equal "group_reference", buckets.loud(:script_error,
      refusal('const all = g.parallel([g.tool({ name: "bash" })]); g.model({ prompt: "p", results: [all] });'))
    assert_equal "reference_value", buckets.loud(:script_error,
      refusal('g.tool({ name: "bash" }); g.model({ prompt: "p", results: ["tool-1"] });')),
      "a string key is no handle"
    assert_equal "nested_list", buckets.loud(:script_error,
      refusal('const runs = ["a", "b"].map((d) => g.tool({ name: "bash" })); g.parallel(runs); g.model({ prompt: "p", results: [runs] });')),
      "the array a .map built, nested in the list"
    # A chain a g.parallel returned, named as an entry of a list, is its own defect: the nested
    # list's repair would tell the author to write what they wrote. Its bucket keys on the chain
    # sentence's own words, whichever verb and option it names.
    [%w[model results], %w[tool after]].each do |verb, name|
      chain = "g.#{verb}: #{name}: an entry is a chain [a, b], not a step; name each chain's last step: " \
              "#{name}: chains.map((c) => c[c.length - 1])."
      assert_equal "chain_reference", buckets.loud(:script_error, chain), "g.#{verb} #{name}"
    end

    first = evaluate(%Q|g.tool({ name: "bash", input: { command: "a" }\n g.model({ prompt: "one" });|)
    second = evaluate(%Q|g.model({ prompt: "two" });\ng.tool({ name: "grep", input: { pattern: "b" }\n g.model({ prompt: "three" });|)
    assert_equal %w[syntax syntax], [first, second].map { |built| buckets.loud(built.refusal, built.detail) }
    assert_includes first.detail, %( at line 2, column 2: g.model({ prompt: "one" });)
    assert_equal "SyntaxError: Unexpected identifier 'g'", buckets.normalize(first.detail)
    assert_equal buckets.normalize(first.detail), buckets.normalize(second.detail),
      "the position and the echoed source never key a group"

    ["is not defined", "is not an option"].each do |phrase|
      echoed = evaluate(%Q|g.model({ prompt: "Report every word that #{phrase}" ));|)
      assert_equal :script_syntax_error, echoed.refusal, phrase
      assert_includes echoed.detail, phrase, "the refusal echoes the author's line, an earlier row's phrase in it"
      assert_equal "syntax", buckets.loud(echoed.refusal, echoed.detail), "the echoed source never picks a bucket: #{phrase}"
    end
  end
end
