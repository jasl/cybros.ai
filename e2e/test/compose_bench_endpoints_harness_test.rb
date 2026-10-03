require_relative "compose_bench_harness"

# THE MECHANISM ENDPOINTS, four facts over the steps a first script built — what a re-cut of the
# compose text is written to move, read identically on every arm: a whole-plan wrapper, a loop of
# independent steps left ungrouped, and the labels and success filters a race's members author.
class ComposeBenchEndpointsHarnessTest < Minitest::Test
  include ComposeBenchHarness

  # Synthetic map, loop and helper forms, with one explicitly grouped counterpart.
  SYNTHETIC = JSON.parse(File.read(File.expand_path("../support/fixtures/compose_scripts/grep_then_edit.json", __dir__),
    encoding: Encoding::UTF_8)).freeze

  # NO ENDPOINT READS A READ BY POSITION: a step reads only what it names, so the positional facts —
  # a reader over-fed after a group, a closing gather — have no mechanism left to measure, and what
  # a script names is counted off the stored script by the analyzer, one code path for every arm.
  def test_the_endpoints_are_the_four_that_read_no_position
    assert_equal %w[whole_plan_wrapper ungrouped_loop authored_labels success_filter], E2E::ComposeBench::Endpoints::NAMES
    assert_equal E2E::ComposeBench::Endpoints::NAMES, read(CANONICAL.fetch("O7b")).keys
  end

  def test_a_plan_that_is_one_result_free_stage_is_a_whole_plan_wrapper
    assert read("g.script({ script: #{JSON.generate(CANONICAL.fetch("O4"))} });")["whole_plan_wrapper"]
    refute read(<<~JS)["whole_plan_wrapper"], "a stage beside other steps is not the whole plan"
      g.tool({ name: "bash", input: { command: "bin/setup" } });
      g.script({ script: #{JSON.generate(CANONICAL.fetch("O4"))} });
    JS
    refute read(CANONICAL.fetch("O2"))["whole_plan_wrapper"]
  end

  def test_a_loop_of_independent_steps_is_ungrouped_until_its_handles_are_grouped
    %w[ungrouped-map ungrouped-for ungrouped-helper].each do |run|
      assert read(SYNTHETIC.fetch(run).fetch("script"), params: SYNTHETIC.fetch(run).fetch("params"))["ungrouped_loop"], run
    end
    grouped = SYNTHETIC.fetch("grouped-map")
    refute read(grouped.fetch("script"), params: grouped.fetch("params"))["ungrouped_loop"],
      "the same loop, its handles grouped"
  end

  # One call site that ran more than once is the loop, whatever spells it: `for`, a helper called
  # in turn. Steps written one call each — on their own lines or all on one — are the author's
  # order, and a loop whose steps chain by `after:` wrote that order on purpose.
  def test_only_one_call_site_placing_independent_steps_in_a_row_is_an_ungrouped_loop
    assert read(<<~'JS')["ungrouped_loop"], "a for loop of reviews"
      for (const angle of ["security", "performance"]) {
        g.model({ prompt: "Review patch.diff for " + angle + "." });
      }
    JS
    assert read(<<~'JS')["ungrouped_loop"], "a helper called in turn"
      const grep = (path) => g.tool({ name: "grep", input: { pattern: "def full_name", path: path } });
      grep("app/models/user.rb");
      grep("app/models/team.rb");
    JS
    refute read(<<~'JS')["ungrouped_loop"], "written out by hand"
      g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } });
    JS
    refute read('g.tool({ name: "bash", input: { command: "a" } }); g.tool({ name: "bash", input: { command: "b" } });')["ungrouped_loop"],
      "two calls on one line are two call sites"
    refute read(<<~'JS')["ungrouped_loop"], "a chain the loop wrote with after:"
      let previous = g.tool({ name: "bash", input: { command: "bin/rails db:create" } });
      ["db:migrate", "db:seed"].forEach((task) => {
        previous = g.tool({ name: "bash", input: { command: "bin/rails " + task }, after: [previous] });
      });
    JS
    assert read(<<~'JS')["ungrouped_loop"], "a map's independent steps, then a step through the same helper naming them"
      const run = (command, after) => g.tool({ name: "bash", input: { command: command }, after: after });
      const checks = ["bin/rubocop", "bin/rails test"].map((c) => run(c));
      run("echo checked", checks);
    JS
  end

  # A turn may hold a group — fetch, then two readers of it at once — and the turns still run one
  # after another when nothing groups the loop; a loop of whole groups is the same loop.
  def test_a_loop_whose_turn_holds_a_group_left_ungrouped_is_an_ungrouped_loop
    assert read(<<~'JS')["ungrouped_loop"], "a for loop of [fetch, a group of two readers]"
      for (const s of ["a", "b", "c"]) {
        const feed = g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" } });
        g.parallel([g.model({ prompt: "Normalise " + s + ".", results: [feed] }), g.model({ prompt: "Lint " + s + ".", results: [feed] })]);
      }
      g.model({ prompt: "Merge the three." });
    JS
    assert read(<<~'JS')["ungrouped_loop"], "a map of whole groups"
      ["a", "b"].map((s) => g.parallel([g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" } }), g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/meta" } })]));
    JS
    refute read(<<~'JS')["ungrouped_loop"], "each turn's fetch waits on the group before it by after:"
      let last = [];
      for (const s of ["a", "b"]) {
        const feed = g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" }, after: last });
        const readers = [g.model({ prompt: "Normalise " + s + ".", results: [feed] }), g.model({ prompt: "Lint " + s + ".", results: [feed] })];
        g.parallel(readers);
        last = readers;
      }
    JS
  end

  # A loop's turn may place a chain — fetch, then normalise — and the turns still run one after
  # another when nothing groups them: O7's pairs with the `g.parallel(pairs)` left out (the P4
  # defect), in a `for` loop or a one-line `.map`. Grouped, the same loop places a `g.parallel`.
  def test_a_loop_whose_turn_places_a_chain_left_ungrouped_is_an_ungrouped_loop
    assert read(<<~'JS')["ungrouped_loop"], "a for loop of [fetch, normalise]"
      for (const s of ["a", "b", "c"]) {
        g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" } });
        g.model({ prompt: "Normalise source " + s + "." });
      }
      g.model({ prompt: "Merge the three." });
    JS
    pairs = <<~'JS'
      const pairs = ["a", "b", "c"].map((s) => [g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" } }), g.model({ prompt: "Normalise source " + s + "." })]);
    JS
    assert read(pairs + 'g.model({ prompt: "Merge the three." });')["ungrouped_loop"], "a one-line map of pairs, never grouped"
    refute read(pairs + "g.parallel(pairs);\n" + 'g.model({ prompt: "Merge the three." });')["ungrouped_loop"], "the same pairs, grouped"
    refute read(<<~'JS')["ungrouped_loop"], "each turn chained to the one before by after:"
      let last = null;
      for (const s of ["a", "b"]) {
        const fetched = g.tool({ name: "bash", input: { command: "curl -s https://" + s + ".example/feed" }, after: last ? [last] : [] });
        last = g.model({ prompt: "Normalise source " + s + ".", results: [fetched] });
      }
    JS
  end

  # ── the labels the envelope's `<call>` line makes redundant ─────────────
  # Echoed host tags and per-member tagging stages label a race; a positional lookup after
  # the race only interprets its results.
  RACE_SYNTHETIC = {
    "echo-labels" => <<~'JS',
      const alpha = g.tool({ name: "bash", input: { command: "bin/probe alpha && echo PROBE_OK host=alpha" } });
      const bravo = g.tool({ name: "bash", input: { command: "bin/probe bravo && echo PROBE_OK host=bravo" } });
      const charlie = g.tool({ name: "bash", input: { command: "bin/probe charlie && echo PROBE_OK host=charlie" } });
      g.parallel([alpha, bravo, charlie], { until: "any" });
      g.model({ prompt: "Report the winner of the race from the result above." });
    JS
    "stage-labels" => <<~'JS',
      const chains = ["alpha", "bravo", "charlie"].map(h => {
        const probe = g.tool({ name: "bash", input: { command: "bin/probe " + h } });
        const tag = g.script({
          results: [probe],
          script: `const r = results[0]; return { host: ${JSON.stringify(h)}, ok: r.status === "completed" && !r.is_error, output: (r.output || "").trim() };`
        });
        return [probe, tag];
      });
      g.parallel(chains, { until: "any" });
      g.model({ prompt: "Report which host won." });
    JS
    "unlabelled" => <<~'JS',
      const alpha = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
      const bravo = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
      const charlie = g.tool({ name: "bash", input: { command: "bin/probe charlie" } });
      g.parallel([alpha, bravo, charlie], { until: "any" });
      g.model({ prompt: "Name the host that won the race." });
    JS
    "positional-table" => <<~'JS',
      g.script({
        script: `
          const hosts = ["alpha", "bravo", "charlie"];
          const probes = hosts.map(function(h) {
            return g.tool({ name: "bash", input: { command: "bin/probe " + h } });
          });
          g.parallel(probes, { until: "any" });
          g.script({
            results: probes,
            script: "const hosts = ['alpha', 'bravo', 'charlie'];" +
              "for (let i = 0; i < results.length; i++) {" +
              "  const r = results[i];" +
              "  if (r && r.status === 'completed' && !r.is_error) { return { winner: hosts[i], output: r.output }; }" +
              "}" +
              "throw new Error('no probe succeeded');"
          });
        `
      });
    JS
  }.freeze

  def test_an_echo_tag_or_a_stage_adding_a_literal_is_a_label_and_a_positional_table_is_not
    labels = RACE_SYNTHETIC.transform_values { |script| read(script)["authored_labels"] }
    assert_equal({ "echo-labels" => true, "stage-labels" => true, "unlabelled" => false, "positional-table" => false }, labels)
    refute read(CANONICAL.fetch("O3"))["authored_labels"], "a probe_host input names its host: the call is the label"
    same_echo = RACE_SYNTHETIC.fetch("echo-labels").gsub(/host=(alpha|bravo|charlie)/, "host=up")
    refute read(same_echo)["authored_labels"], "an echo every member prints alike tells nothing apart"
  end

  # A member's throwing stage filters its success; a stage after the race cannot filter members.
  def test_a_race_whose_members_throw_on_their_own_outcome_is_a_success_filter
    tagged = <<~'JS'
      const probeAlpha = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
      const tagAlpha = g.script({ results: [probeAlpha], script: "const r = results[0]; if (r.status !== 'completed' || r.is_error) { throw new Error('probe of alpha failed'); } return { host: 'alpha', output: r.output };" });
      const probeBravo = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
      const tagBravo = g.script({ results: [probeBravo], script: "const r = results[0]; if (r.status !== 'completed' || r.is_error) { throw new Error('probe of bravo failed'); } return { host: 'bravo', output: r.output };" });
      g.parallel([[probeAlpha, tagAlpha], [probeBravo, tagBravo]], { until: "any" });
      g.model({ prompt: "Name the host in the result above." });
    JS
    assert_equal [true, true], read(tagged).values_at("authored_labels", "success_filter")

    shared = <<~'JS'
      const chains = ["alpha", "bravo", "charlie"].map(h => {
        const probe = g.tool({ name: "bash", input: { command: "bin/probe " + h } });
        return [probe, g.script({ results: [probe], script: "const r = results[0]; if (r.is_error) throw new Error('down'); return r.output;" })];
      });
      g.parallel(chains, { until: "any" });
      g.model({ prompt: "Which host won?" });
    JS
    assert_equal [false, true], read(shared).values_at("authored_labels", "success_filter")
    assert_equal [false, false], read(shared.sub('{ until: "any" }', "{}")).values_at("authored_labels", "success_filter")
    refute read(RACE_SYNTHETIC.fetch("positional-table"))["success_filter"], "the stage after the race is no member's filter"

    wrapped = <<~'JS'
      g.script({
        script: `
          const wrap = function (probe, host) {
            return g.script({ results: [probe], params: { host: host },
              script: 'const r = results[0]; if (r.is_error || r.status !== "completed") { throw new Error(params.host + " did not respond"); } return { host: params.host, output: r.output };' });
          };
          const alpha = g.tool({ name: "bash", input: { command: "bin/probe alpha" } });
          const bravo = g.tool({ name: "bash", input: { command: "bin/probe bravo" } });
          g.parallel([wrap(alpha, "alpha"), wrap(bravo, "bravo")], { until: "any" });
          g.model({ prompt: "Name the winner." });
        `
      });
    JS
    assert_equal [true, true], read(wrapped).values_at("authored_labels", "success_filter")
  end

  private

    def read(script, params: {})
      built = evaluate(script, params: params)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      E2E::ComposeBench::Endpoints.read(built, script: script, expanded: Shape.inline(built.steps, tool_names: Tools::NAMES).steps)
    end
end
