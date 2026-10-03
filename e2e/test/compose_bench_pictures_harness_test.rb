require_relative "compose_bench_harness"
require "support/evals/trace"

# THE PICTURES: every objective's picture is exactly what its canonical scripts lower to (the
# lowering is `compose_bench_lowering_harness_test.rb`'s), and a near-miss lands in the named silent
# bucket, never in "exact".
class ComposeBenchPicturesHarnessTest < Minitest::Test
  include ComposeBenchHarness

  # O7b's other spelling — the pi thunk habit — lowers to the same picture: the thunk's summary is
  # a handle the report names like any other.
  O7B_AS_FUNCTION = <<~JS.freeze
    const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
    const testSummary = g.model({ prompt: "Summarise the test failures.", results: [tests] });
    let qualitySummary;
    g.parallel([
      [tests, testSummary],
      () => {
        const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
        const types = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
        g.parallel([lint, types]);
        qualitySummary = g.model({ prompt: "Summarise code quality from lint and types.", results: [lint, types] });
      },
    ]);
    g.model({ prompt: "Write the report from the two summaries.", results: [testSummary, qualitySummary] });
  JS

  # EVERY PICTURE IS THE STATED PROPERTY: each canonical script per objective — and the second
  # spelling of the two a step's position used to spoil — through the shipped evaluator and this
  # lowering, scores exact on both columns. Waits compare reduced, so a picture that wrote an
  # implied wait could never match: each is its own reduction.
  def test_every_picture_is_exact_for_its_canonical_scripts
    [*CANONICAL, *SECOND_CANONICAL].each do |id, script|
      objective = Objectives.find(id)
      score = objective.picture.score(lower(script))
      assert score["exact_edges"] && score["exact_reads"], "#{id}: #{score.inspect}"
    end
    Objectives::ALL.reject(&:control?).each do |objective|
      assert_equal objective.picture.edges.sort, objective.picture.reduced_edges.sort, "#{objective.id} writes an implied wait"
    end
    graph = lower(CANONICAL.fetch("O7b"))
    assert_equal [%w[model-1 model-3], %w[model-2 model-3], %w[tool-1 model-1], %w[tool-2 model-2], %w[tool-3 model-2]],
      graph.edges.sort, "O7b: t→ts, l→qs, ty→qs, ts→report, qs→report"
    assert_equal({ "model-1" => %w[tool-1], "model-2" => %w[tool-2 tool-3], "model-3" => %w[model-1 model-2] }, graph.reads)
    assert_equal graph.reads, lower(SECOND_CANONICAL.fetch("O7b")).reads,
      "the flat peers read what the nested pairs read: each step what it names"
    assert Objectives.find("O7b").picture.score(lower(O7B_AS_FUNCTION)).values_at("exact_edges", "exact_reads").all?
  end

  # Waiting for earlier work does not implicitly pass its result to a model.
  # This graph has the rendezvous waits but leaves every review blind.
  T5_BLIND_REVIEWS = <<~JS.freeze
    g.parallel([
      g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } }),
      g.tool({ name: "bash", input: { command: "bin/rails db:seed" } }),
    ]);
    g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" } });
    g.parallel([
      g.model({ prompt: "Review migrations." }),
      g.model({ prompt: "Review seeds." }),
    ]);
    g.model({ prompt: "Merge reviews." });
  JS

  def test_the_rendezvous_picture_isolates_each_review_as_its_prompt_asks
    picture = Objectives.find("T5").picture
    assert_equal({ "rm" => %w[mig dump], "rs" => %w[seed dump], "merge" => %w[rm rs] }, picture.reads)
    isolated = lower(CANONICAL.fetch("T5"))
    assert_equal({ "model-1" => %w[tool-1 tool-3], "model-2" => %w[tool-2 tool-3], "model-3" => %w[model-1 model-2] },
      isolated.reads.transform_values(&:sort), "peers naming their inputs in results: read those alone")
    assert_equal isolated.reads, lower(SECOND_CANONICAL.fetch("T5")).reads, "the merge after the group reads what it names"

    graph = lower(T5_BLIND_REVIEWS)
    assert_equal({ "model-1" => [], "model-2" => [], "model-3" => [] }, graph.reads,
      "no review and no merge names anything, so each reads its prompt alone")
    score = picture.score(graph)
    assert score["exact_edges"], "written order waits exactly as the rendezvous does: #{score.inspect}"
    refute score["exact_reads"]
    assert_equal ["blind_model"], score["silent"]
  end

  # A log-reading tool before a review is another wait, not a result binding.
  # It adds a step to each branch while the reviews still read nothing.
  T5_UNBOUND_LOG_READS = <<~JS.freeze
    g.parallel([
      g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } }),
      g.tool({ name: "bash", input: { command: "bin/rails db:seed" } }),
    ]);
    g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" } });
    g.parallel([
      [g.tool({ name: "bash", input: { command: "cat migrate.log" } }), g.model({ prompt: "Review migrations." })],
      [g.tool({ name: "bash", input: { command: "cat seed.log" } }), g.model({ prompt: "Review seeds." })],
    ]);
    g.model({ prompt: "Merge reviews." });
  JS

  def test_the_rendezvous_pair_that_cats_its_own_log_isolates_nothing
    graph = lower(T5_UNBOUND_LOG_READS)
    assert_equal({ "model-1" => [], "model-2" => [], "model-3" => [] }, graph.reads, "a cat before a review is a wait, not a read")
    score = Objectives.find("T5").picture.score(graph)
    refute score["exact_edges"]
    refute score["exact_reads"]
    assert_equal %w[extra_steps blind_model], score["silent"]
  end

  # THE NEAR-MISSES land in the named bucket, never in "exact".
  def test_the_silent_buckets_name_the_defect
    o7 = Objectives.find("O7").picture.score(lower(<<~JS))
      const fetches = ["a", "b", "c"].map((source) => g.tool({ name: "bash", input: { command: source } }));
      g.parallel(fetches);
      const normalised = fetches.map((fetch) => g.model({ prompt: "normalise", results: fetches }));
      g.parallel(normalised);
      g.model({ prompt: "merge", results: [...fetches, ...normalised] });
    JS
    refute o7["exact_edges"]
    assert_equal %w[over_sync over_read_named], o7["silent"], "each normaliser names every fetch, the merge the fetches too"

    o2 = Objectives.find("O2").picture.score(lower(<<~JS))
      g.parallel([g.tool({ name: "grep", input: { pattern: "x", path: "a" } }), g.tool({ name: "grep", input: { pattern: "x", path: "b" } }), g.tool({ name: "grep", input: { pattern: "x", path: "c" } })]);
      g.tool({ name: "edit", input: { path: "a", old_text: "full_name", new_text: "display_name" } });
    JS
    assert_equal ["edit_as_tool"], o2["silent"]

    staged = Objectives.find("O2").picture.score(lower(<<~JS))
      const a = g.tool({ name: "grep", input: { pattern: "x", path: "a" } });
      const b = g.tool({ name: "grep", input: { pattern: "x", path: "b" } });
      const c = g.tool({ name: "grep", input: { pattern: "x", path: "c" } });
      g.parallel([a, b, c]);
      g.script({ results: [a, b, c], script: "return results.map(r => r.output);" });
    JS
    assert_equal ["edit_as_stage"], staged["silent"]

    o3 = Objectives.find("O3").picture.score(lower(<<~JS))
      g.parallel([g.tool({ name: "probe_host", input: { host: "a" } }), g.tool({ name: "probe_host", input: { host: "b" } }), g.tool({ name: "probe_host", input: { host: "c" } })]);
      g.model({ prompt: "who" });
    JS
    assert_includes o3["silent"], "missing_join"

    o4 = Objectives.find("O4").picture.score(lower(<<~JS))
      const suite = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      g.model({ prompt: "fix", results: [suite, lint] });
    JS
    refute o4["exact_edges"], "a sequential suite; lint; fix makes the fix wait on the suite"
    assert_includes o4["silent"], "suite_waited_on"
    assert_includes o4["silent"], "over_read_named", "and name it"
    refute_includes o4["silent"], "over_read_positional", "no read on a script's lowering is positional"
  end

  # A GRAPH WITH NO EDGE WAITS ON NOTHING: `suite_waited_on` names a tip the picture leaves free
  # that a later step waits on, so an empty plan (a whole-plan stage that failed or returned a
  # value) or a row of unconnected steps never reads it, whatever the picture's free tips.
  def test_a_graph_that_waits_on_nothing_never_reads_the_suite_waited_on
    empty = Shape::Graph.new(nodes: [], edges: [])
    assert_equal %w[missing_join missing_steps], Objectives.find("O3").picture.score(empty)["silent"]
    refute_includes Objectives.find("O4").picture.score(empty)["silent"], "suite_waited_on"
  end

  # A WAIT THE CHAIN ALREADY MAKES IS NO DEFECT: the merge's `after:` restates that it waits on
  # each fetch, which it does through the fetch's own normaliser. Waits compare reduced, so the
  # script is the picture; the canonical T5 does the same with `results:` (a review names the
  # migrate output the dump already waited on).
  def test_a_restated_wait_reads_exact
    graph = lower(<<~JS)
      const a = g.tool({ name: "bash", input: { command: "curl -s https://a.example/feed" } });
      const b = g.tool({ name: "bash", input: { command: "curl -s https://b.example/feed" } });
      const c = g.tool({ name: "bash", input: { command: "curl -s https://c.example/feed" } });
      const na = g.model({ prompt: "Normalise source a.", results: [a] });
      const nb = g.model({ prompt: "Normalise source b.", results: [b] });
      const nc = g.model({ prompt: "Normalise source c.", results: [c] });
      g.parallel([[a, na], [b, nb], [c, nc]]);
      g.model({ prompt: "Merge the three normalised sets.", results: [na, nb, nc], after: [a, b, c] });
    JS
    assert_includes graph.edges, %w[tool-1 model-4], "the restated wait is written"
    score = Objectives.find("O7").picture.score(graph)
    assert score["exact_edges"] && score["exact_reads"], score.inspect
  end

  # Reducing implied edges must retain a real serial dependency. Three searches
  # written in sequence and two checks in the same branch both over-synchronize.
  SERIAL_GRAPHS = {
    "serial searches" => ["O2", <<~'JS'],
      const searches = ["a.rb", "b.rb", "c.rb"].map(path =>
        g.tool({ name: "grep", input: { pattern: "full_name", path } }));
      g.model({ prompt: "Rename the definition.", results: searches });
    JS
    "serial quality checks" => ["O7b", <<~'JS'],
      const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const types = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
      const testSummary = g.model({ prompt: "Summarize tests.", results: [tests] });
      const qualitySummary = g.model({ prompt: "Summarize checks.", results: [lint, types] });
      g.parallel([[tests, testSummary], [lint, types, qualitySummary]]);
      g.model({ prompt: "Merge summaries.", results: [testSummary, qualitySummary] });
    JS
  }.freeze

  def test_serial_dependencies_survive_the_reduction
    SERIAL_GRAPHS.each do |name, (id, script)|
      score = Objectives.find(id).picture.score(lower(script))
      refute score["exact_edges"], name
      assert_includes score["silent"], "over_sync", "#{name}: #{score.inspect}"
    end
  end

  # A PATH THROUGH A RACE IMPLIES NOTHING: the step after an `until: "any"` join waits on the join,
  # never on a member, so a reader naming every probe in `results:` waits for the losers the race
  # was written to abandon — over-sync, whether the reader is a model or a stage. Compose refuses the
  # spelling at the line (`race_member`, below); the door still takes it — a member a reader names
  # is shared work the race spares — so the reading stands on the door's step tree.
  def test_a_reader_after_a_race_naming_every_probe_waits_on_the_losers
    probes = %w[alpha bravo charlie].each_with_index.map do |host, index|
      { "tool" => { "key" => "tool-#{index + 1}", "name" => "bash", "input" => { "command" => "bin/probe #{host}" } } }
    end
    race = { "parallel" => probes, "until" => "any", "key" => "parallel-1" }
    stage = [race, { "script" => { "key" => "script-1", "results" => %w[tool-1 tool-2 tool-3], "script" => "return null;" } }]
    model = [race, { "model" => { "key" => "model-1", "prompt" => "Say which host responded first.",
                                  "results" => %w[tool-1 tool-2 tool-3] } }]
    picture = Objectives.find("O3").picture

    assert_includes picture.score(Shape.lower(stage))["silent"], "over_sync", "a stage waiting on every probe"
    waited = picture.score(Shape.lower(model))
    refute waited["exact_edges"]
    assert waited["exact_reads"], "the reads are the race's own"
    assert_equal ["over_sync"], waited["silent"]
    assert picture.score(lower(CANONICAL.fetch("O3"))).values_at("exact_edges", "exact_reads").all?,
      "the race's own edges into its join are never implied away"
  end

  # A SCRIPT'S RACE STOPS THE MEMBERS IT DID NOT SELECT, so compose refuses a later reader naming
  # one — a stage or a model, in `results:` or `after:` — at the line, naming the race, its line and
  # its own `until`, and the repair: `results: [race]`.
  def test_a_reader_naming_a_member_of_a_formed_race_is_refused_with_the_repair
    race = <<~'JS'
      const a = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
      const b = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
      const c = g.tool({ name: "bash", input: { command: "bin/probe charlie" } });
      g.parallel([a, b, c], { until: "any" });
    JS
    sentence = %(results names "tool-1", a member of the race on line 4; a race stops the members it did not select, ) +
      %(so name the race itself: const race = g.parallel([...], { until: "any" }); then results: [race].)
    [%(g.script({ results: [a, b, c], script: "return null;" });\n),
     %(g.model({ prompt: "Say which host responded first.", results: [a, b, c] });\n)].each do |reader|
      detail = refusal(race + reader)
      assert_equal "race_member", E2E::ComposeBench::Buckets.loud(:script_error, detail), reader
      assert_includes detail, sentence, reader
    end
    assert_includes refusal(race + %(g.tool({ name: "bash", input: { command: "echo done" }, after: [b] });\n)),
      %(g.tool: after names "tool-2", a member of the race on line 4)
    quorum = race.sub('{ until: "any" }', "{ until: 2 }")
    assert_includes refusal(quorum + %(g.model({ prompt: "p", results: [c] });\n)), "g.parallel([...], { until: 2 })",
      "the repair echoes the race's own until"
  end

  # O3'S WINNER, NAMED BY THE RACE: `results: [race]` waits on the join alone and reads the probes
  # the race selects from, so a value stage — or a model — naming the race is O3 exactly, where
  # naming the probes one by one waited on the losers.
  def test_a_step_naming_the_race_is_o3_exactly
    race = <<~'JS'
      const a = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
      const b = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
      const c = g.tool({ name: "bash", input: { command: "bin/probe charlie" } });
      const race = g.parallel([a, b, c], { until: "any" });
    JS
    exact = { "exact_edges" => true, "exact_reads" => true, "silent" => [] }
    stage = race + %(g.script({ results: [race], script: "const won = results[0]; if (won.status !== 'completed' || won.is_error) throw new Error('none'); return won.output;" });\n)
    assert_equal exact, scored("O3", stage).slice(*exact.keys), "a value stage reading the race"
    model = race + %(g.model({ prompt: "Say which host responded first.", results: [race] });\n)
    assert_equal exact, scored("O3", model).slice(*exact.keys), "a model reading the race"
    assert_equal exact, Objectives.find("O3").picture.score(lower(stage)), "on the plain lowering too"
  end

  # O7'S MERGE MAY BE A VALUE STAGE: a `g.script` that reads the three normalisers and returns a
  # value stands where the picture has the merge model and is compared on its own reads. A stage
  # whose body places a step is no stand-in, whatever it reads: its run over no results builds
  # the merge model, which is what the kernel runs.
  O7_PAIRS = <<~'JS'.freeze
    const a = g.tool({ name: "bash", input: { command: "curl -s https://a.example/feed" } });
    const b = g.tool({ name: "bash", input: { command: "curl -s https://b.example/feed" } });
    const c = g.tool({ name: "bash", input: { command: "curl -s https://c.example/feed" } });
    const na = g.model({ prompt: "Normalise source a.", results: [a] });
    const nb = g.model({ prompt: "Normalise source b.", results: [b] });
    const nc = g.model({ prompt: "Normalise source c.", results: [c] });
    g.parallel([[a, na], [b, nb], [c, nc]]);
  JS

  def test_a_value_stage_reading_the_normalisers_stands_for_the_merge
    merge = scored("O7", O7_PAIRS + %(g.script({ results: [na, nb, nc], script: "return results.map(r => r.output).join(' ');" });\n))
    assert merge["first_time_right"], merge.inspect

    placing = O7_PAIRS + %(g.script({ results: [na, nb, nc], script: "g.model({ prompt: 'Merge these sets: ' + results.map(r => r.output).join(' | ') });" });\n)
    assert_equal ["script-1"], Shape.inline(evaluate(placing).steps, tool_names: Tools::NAMES).placers
    refute scored("O7", placing)["first_time_right"], "a stage that places the merge is no stand-in for it"
  end

  # O7'S NORMALISER MAY BE A TOOL OR A VALUE STAGE, still its own step after its own fetch and reading
  # that fetch alone: a value stage reads its `results:`, and a tool — whose input is fixed when the
  # script is written, so it computes over what the steps it waits on left behind — reads what it
  # waits on. A tool normaliser that waits on no fetch reads none — blind, as a model reading
  # nothing is — one that waits on every fetch over-syncs, and a normalise folded into its fetch is
  # no step at all. A MODEL merge behind tool or value-stage normalisers reads the three normalised
  # sets it names and nothing the group placed before them: a group hands the step after it nothing
  # to read, so the merge is exact however its normalisers are spelled, and one naming the raw
  # fetches too over-reads by its own names.
  O7_FETCHES = %w[a b c].map { |source| %(const #{source} = g.tool({ name: "bash", input: { command: "sh bin/fetch #{source} > raw.#{source}" } });\n) }.join.freeze
  O7_NORMALISE_TOOLS = %w[a b c].map { |source| %(const n#{source} = g.tool({ name: "bash", input: { command: "sh bin/normalise #{source}" } });\n) }.join.freeze
  O7_VALUE_MERGE = %(g.script({ results: [na, nb, nc], script: "return results.map(r => r.output).join('');" });\n).freeze
  O7_MODEL_MERGE = %(g.model({ prompt: "Merge the three normalised sets.", results: [na, nb, nc] });\n).freeze

  def test_o7s_normaliser_may_be_a_tool_or_a_value_stage_after_its_own_fetch
    pairs = "g.parallel([[a, na], [b, nb], [c, nc]]);\n"
    tools = O7_FETCHES + O7_NORMALISE_TOOLS + pairs + O7_VALUE_MERGE
    assert scored("O7", tools)["first_time_right"], scored("O7", tools).inspect
    stages = O7_FETCHES + %w[a b c].map { |source| %(const n#{source} = g.script({ results: [#{source}], script: "return results[0].output.trim();" });\n) }.join
    assert scored("O7", stages + pairs + O7_VALUE_MERGE)["first_time_right"], "a value stage reading its own fetch"

    assert scored("O7", O7_FETCHES + O7_NORMALISE_TOOLS + pairs + O7_MODEL_MERGE)["first_time_right"],
      "a model merge behind tool normalisers reads the sets it names"
    assert scored("O7", stages + pairs + O7_MODEL_MERGE)["first_time_right"],
      "a model merge behind value-stage normalisers reads the sets it names"
    raw = O7_MODEL_MERGE.sub("results: [na, nb, nc]", "results: [a, b, c, na, nb, nc]")
    assert_equal ["over_read_named"], scored("O7", stages + pairs + raw)["silent"], "a merge naming the raw fetches too"

    blind = scored("O7", O7_FETCHES + O7_NORMALISE_TOOLS + "g.parallel([a, b, c, na, nb, nc]);\n" + O7_VALUE_MERGE)
    refute blind["first_time_right"]
    assert_equal %w[under_sync blind_model], blind["silent"], "a normalise tool beside its fetch waits on nothing and reads nothing"
    barrier = scored("O7", O7_FETCHES + "g.parallel([a, b, c]);\n" + O7_NORMALISE_TOOLS + "g.parallel([na, nb, nc]);\n" + O7_VALUE_MERGE)
    assert_includes barrier["silent"], "over_sync", "each normalise tool waits on every fetch"
    folded = %w[a b c].map { |source| %(const n#{source} = g.tool({ name: "bash", input: { command: "sh bin/fetch #{source} | awk -f norm.awk" } });\n) }.join
    assert_includes scored("O7", folded + "g.parallel([na, nb, nc]);\n" + O7_VALUE_MERGE)["silent"], "missing_steps"
  end

  # O4's suite beside a `[lint, fix, CHECK]` member, CHECK replaced per case; the fix names the lint.
  O4_CHAIN = <<~'JS'.freeze
    const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
    g.parallel([
      g.tool({ name: "bash", input: { command: "bin/rails test" } }),
      [lint, g.model({ prompt: "Fix every offence.", results: [lint] }), CHECK],
    ]);
  JS

  # A STAGE THE KERNEL FAILS IS NEVER A VALUE: one whose source does not parse, one that throws on
  # no results, one whose steps the stage lowering refuses — the static reading knows each
  # (`Inlined#refused`), so none stands in for a model, drops out as the plan's answer, or extends
  # O4's chain; a stage that places the re-lint still extends it.
  def test_a_stage_the_kernel_fails_is_never_a_value
    broken = O7_PAIRS + %{g.script({ results: [na, nb, nc], script: "return results.map(r => r.output" });\n}
    refute scored("O7", broken)["first_time_right"], "a merge that does not parse computes nothing"
    ["return {", "throw new Error('no plan');"].each do |body|
      assert_equal ["extra_steps"], scored("O1", CANONICAL.fetch("O1") + %(g.script({ script: #{JSON.generate(body)} });\n))["silent"], body
    end
    o4 = ->(check) { O4_CHAIN.sub("CHECK", check) }
    refute scored("O4", o4.('g.script({ script: "return {" })'))["first_time_right"], "a check the kernel fails extends nothing"
    assert scored("O4", o4.(%q{g.script({ script: "g.tool({ name: 'bash', input: { command: 'bin/rubocop app' } });" })}))["first_time_right"],
      "a stage that places the re-lint extends the chain"
  end

  # O4'S BUCKETS NAME THE DEFECT, NEVER THE RE-LINT: a suite run by a model beside `[lint, fix,
  # re-lint]` is blind, and the re-lint ruling (c) admits is read as the extension it is
  # The fixture isolates the follower's read dependency.
  def test_o4s_buckets_read_the_graph_without_its_admitted_extensions
    suite = O4_CHAIN.sub('g.tool({ name: "bash", input: { command: "bin/rails test" } })', 'g.model({ prompt: "Run the whole test suite." })')
    assert_equal ["blind_model"], scored("O4", suite.sub("CHECK", 'g.tool({ name: "bash", input: { command: "bin/rubocop app" } })'))["silent"]
  end

  # A VALUE THAT IS THE MERGE HOLDS THE MERGE'S PLACE in the buckets beside a stray model too: the
  # same dataflow reads the same buckets whether the merge is a model or a value stage.
  def test_a_value_merge_beside_a_stray_model_reads_as_the_model_merge_does
    stray = O7_PAIRS.sub("g.parallel([[a, na], [b, nb], [c, nc]]);",
      %(g.parallel([[a, na], [b, nb], [c, nc], g.model({ prompt: "Summarise feed a.", results: [a] })]);))
    model = scored("O7", stray + %(g.model({ prompt: "Merge the three normalised sets.", results: [na, nb, nc] });\n))["silent"]
    value = scored("O7", stray + %(g.script({ results: [na, nb, nc], script: "return results.map(r => r.output).join(' ');" });\n))["silent"]
    assert_includes value, "extra_steps", "the stray is the extra step, never read as the merge"
    assert_equal model, value
  end

  # THE BUCKETS NEVER DEPEND ON THE ORDER two tied closing stages are written: the one that reads
  # what the label pictures holds the label.
  def test_the_buckets_do_not_depend_on_the_order_two_closing_stages_are_written
    over = O7_PAIRS.sub('const nc = g.model({ prompt: "Normalise source c.", results: [c] });',
      'const nc = g.model({ prompt: "Normalise source c.", results: [c, a] });')
    reader = %(g.script({ results: [na, nb, nc], script: "return results.length;" }))
    blind = %(g.script({ after: [na, nb, nc], script: "return 1;" }))
    one = scored("O7", "#{over}g.parallel([#{reader}, #{blind}]);\n")["silent"]
    assert_equal one, scored("O7", "#{over}g.parallel([#{blind}, #{reader}]);\n")["silent"]
    assert_equal %w[over_sync over_read_named], one
  end

  def test_a_model_is_never_admitted_in_another_kinds_place
    error = assert_raises(ArgumentError) { E2E::ComposeBench::Picture.new(nodes: { "a" => "tool", "x" => "tool|model" }, edges: [], reads: {}) }
    assert_match(/never admitted/, error.message)
  end

  # ONLY A LABEL THAT ADMITS A TOOL COMPUTES OVER WHAT IT WAITS ON: `computes:` says how a tool at
  # the label reads, so naming a label that admits none — or no label — is the picture's own fault.
  def test_computes_names_only_a_label_that_admits_a_tool
    %w[m x].each do |label|
      error = assert_raises(ArgumentError) do
        E2E::ComposeBench::Picture.new(nodes: { "a" => "tool", "m" => "model|script" }, edges: [%w[a m]], reads: { "m" => %w[a] }, computes: [label])
      end
      assert_match(/names a label that admits no tool/, error.message)
    end
    assert_equal %w[na nb nc], Objectives.find("O7").picture.computes
  end

  # A STAND-IN READS WRONG IN THE BUCKET A MODEL WOULD: a value stage at the merge that reads the
  # fetches too over-reads, one that reads nothing is blind — never a bucket of its own for being
  # spelled as a stage — and the record shows the reads it was compared on.
  def test_a_value_stage_reading_wrong_lands_in_the_models_bucket
    over = scored("O7", O7_PAIRS + %(g.script({ results: [a, b, c, na, nb, nc], script: "return 1;" });\n))
    assert_equal ["over_read_named"], over["silent"]
    assert_equal %w[tool-1 tool-2 tool-3 model-1 model-2 model-3], over.dig("graph", "reads", "script-1"),
      "the stand-in's reads ride the record"
    assert_equal ["blind_model"], scored("O7", O7_PAIRS + %(g.script({ script: "return 1;" });\n))["silent"]
  end

  # A TRAILING VALUE IS THE PLAN'S ANSWER, NOT A STEP: a stage no label takes, that nothing waits
  # on and that places nothing drops out before the comparison, so the recommended ending — one
  # readable leaf such as a `g.script` returning a value — never reads as an extra step.
  def test_a_trailing_value_stage_after_an_exact_plan_drops_out
    o7 = O7_PAIRS + <<~'JS'
      const merge = g.model({ prompt: "Merge the three normalised sets.", results: [na, nb, nc] });
      g.script({ results: [merge], script: "return results[0].output;" });
    JS
    assert scored("O7", o7)["first_time_right"], "O7 with a value reducer after its merge"
    o1 = <<~'JS'
      const reviews = [g.model({ prompt: "Security." }), g.model({ prompt: "Performance." }), g.model({ prompt: "Style." })];
      g.parallel(reviews);
      const verdict = g.model({ prompt: "Weigh the three reviews and give one verdict.", results: reviews });
      g.script({ results: [verdict], script: "return { verdict: results[0].output };" });
    JS
    assert scored("O1", o1)["first_time_right"], "O1 with a value reducer after its verdict"
  end

  # O4 ADMITS STEPS THAT EXTEND [lint → fix]: a re-lint reading the fix and a report reading the
  # chain may follow the fix, while nothing waits on or reads the suite, the fix reads the lint
  # alone and the lint precedes the fix. A step that reads the suite, a step between the lint and
  # the fix, or a re-lint before the fix is no extension.
  O4_HEAD = <<~'JS'.freeze
    const suite = g.tool({ name: "bash", input: { command: "bin/rails test" } });
    const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
    const fix = g.model({ prompt: "Fix every offence the lint output names.", results: [lint] });
  JS
  RELINT = %(const relint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });\n).freeze

  def test_steps_that_extend_the_lint_and_fix_chain_read_exact
    extended = O4_HEAD + RELINT + <<~'JS'
      const report = g.model({ prompt: "Report what the fix changed and what the re-lint says.", results: [lint] });
      g.parallel([suite, [lint, fix, relint, report]]);
    JS
    assert scored("O4", extended)["first_time_right"], scored("O4", extended).inspect
    assert scored("O4", CANONICAL.fetch("O4"))["first_time_right"]

    reads_the_suite = O4_HEAD + RELINT + %(g.parallel([suite, [lint, fix, relint]]);\ng.model({ prompt: "Report the suite and the fix." });\n)
    between = O4_HEAD + %(const cat = g.tool({ name: "bash", input: { command: "cat .rubocop.yml" } });\ng.parallel([suite, [lint, cat, fix]]);\n)
    before = O4_HEAD + RELINT + %(g.parallel([suite, [lint, relint, fix]]);\n)
    { "a report reading the suite" => reads_the_suite, "a step between the lint and the fix" => between,
      "a re-lint before the fix" => before }.each do |name, script|
      refute scored("O4", script)["first_time_right"], name
    end
    assert_includes scored("O4", reads_the_suite)["silent"], "suite_waited_on"
  end

  # O2 ADMITS A VERIFICATION AFTER ITS EDIT: a grep after the edit waits on it and reads nothing the
  # greps did not lead to, so it extends the edit's chain; a grep between the greps and the edit is no
  # extension but an extra step, which the edit, naming the greps alone, never reads.
  def test_a_verify_grep_after_o2s_edit_extends_the_chain
    verify = %(g.tool({ name: "grep", input: { pattern: "def display_name", path: "app/models/team.rb" } });\n)
    verified = scored("O2", CANONICAL.fetch("O2") + verify)
    assert verified["first_time_right"], verified.inspect
    greps, edit = CANONICAL.fetch("O2").split(/(?=g\.model)/)
    assert_equal %w[extra_steps], scored("O2", greps + verify + edit)["silent"]
  end

  # A STAGE IN THE EDIT'S PLACE: a `g.script` reading the greps where O2's edit goes takes the edit's
  # label under the closest correspondence — the picture admits no stage there, and a picture with a
  # tail sets no value apart — and, with nothing else wrong, is named as one rather than left to the
  # fallback; a verify grep after it is the tail's and changes nothing; a blind edit after it is the
  # guessed edit and the extra step; a stage a later model reads is that model's filter and stays in
  # the fallback, since the model may have decided the edit — on the executed reading such a plan is
  # exact; a stage that placed the edit is O2's edit on the executed reading and stays exact.
  def test_a_stage_in_o2s_edits_place_is_named
    greps = <<~JS
      const a = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      const b = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/account.rb" } });
      const c = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } });
      g.parallel([a, b, c]);
    JS
    stage = %(g.script({ results: [a, b, c], script: "return results.map(r => r.output);" });\n)
    assert_equal %w[edit_as_stage], scored("O2", greps + stage)["silent"]
    verify = %(g.tool({ name: "grep", input: { pattern: "def display_name", path: "app/models/team.rb" } });\n)
    assert_equal %w[edit_as_stage], scored("O2", greps + stage + verify)["silent"]
    blind = %(g.tool({ name: "edit", input: { path: "app/models/team.rb", old_string: "full_name", new_string: "display_name" } });\n)
    assert_equal %w[edit_as_tool extra_steps], scored("O2", greps + stage + blind)["silent"]
    filter = %(const which = g.script({ results: [a, b, c], script: "return 'app/models/team.rb';" });\n)
    decide = %(g.model({ prompt: "Rename full_name to display_name in the file the stage above named.", results: [which] });\n)
    assert_equal %w[wrong_task_read], scored("O2", greps + filter + decide)["silent"]
  end

  # O2'S TAIL NEVER TAKES A GUESSED EDIT: an `edit` written into the script read nothing, so it was
  # decided before the greps answered — the fault O2 exists for — wherever it stands: after a model
  # step that read the greps (and may only have reported them) as much as after a decided edit. A
  # shell command past the edit extends the chain as a test run after a patch does: the picture
  # reads no command, and the files on disk are task pass's to read.
  def test_o2s_tail_never_takes_a_blind_edit
    greps, = CANONICAL.fetch("O2").split(/(?=g\.model)/)
    report = %(g.model({ prompt: "Say which file defines full_name.", results: [user, account, team] });\n)
    blind = %(g.tool({ name: "edit", input: { path: "app/models/team.rb", old_string: "full_name", new_string: "display_name" } });\n)
    assert_equal %w[extra_steps], scored("O2", greps + report + blind)["silent"]
    assert_equal %w[extra_steps], scored("O2", CANONICAL.fetch("O2") + blind)["silent"]
    shell = %(g.tool({ name: "bash", input: { command: "bin/rails test" } });\n)
    assert scored("O2", CANONICAL.fetch("O2") + shell)["first_time_right"]
  end

  # THE EDITS ARE THE EVALS': the tools O2's tail refuses written blind are the ones the trace says
  # change the files by construction.
  def test_the_tools_that_edit_are_the_traces
    assert_equal E2E::Evals::Trace::MUTATING_TOOLS.sort, Shape::EDITS.sort
  end

  # EXACT WAITS, WRONG READS: the verdict waits on all three reviews and reads two of them. The
  # reads-only mismatch has its own bucket.
  def test_a_reads_only_mismatch_is_named_as_one
    score = Objectives.find("O1").picture.score(lower(<<~JS))
      const security = g.model({ prompt: "Read patch.diff and review it for security problems." });
      const performance = g.model({ prompt: "Read patch.diff and review it for performance problems." });
      const style = g.model({ prompt: "Read patch.diff and review it for style." });
      const verdict = g.model({ prompt: "Weigh the reviews and give one verdict.", results: [security, performance], after: [style] });
      g.parallel([security, performance, style, verdict]);
    JS
    assert score["exact_edges"]
    refute score["exact_reads"]
    assert_equal ["reads_mismatch"], score["silent"]
  end

  private

    # The static reading the evals record beside the executed one: the script through the shipped
    # evaluator and `Scoring`, which knows which stages place steps.
    def scored(id, script)
      scored = E2E::ComposeBench::Scoring.score(Objectives.find(id), script: script, params: {}, tool_names: Tools::NAMES)
      flunk "#{scored["refusal"]}: #{scored["detail"]}" unless scored["valid_first"]
      scored
    end
end
