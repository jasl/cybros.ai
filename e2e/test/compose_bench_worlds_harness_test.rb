require_relative "compose_bench_harness"
require "support/compose_bench/rehearsal"

# THE REHEARSAL'S WORLDS: what each call a plan places answers in the world its objective declares.
# The tools answer by the harness's own contract (`Tools`), the shell runs the eval environment's own
# stand-ins, and where no pre-data source says how an answer is spelled the world is a DIMENSION with
# two admissible spellings: the plainest first (W0), the runner's second. A race times its exits by the
# stand-ins' own sleeps, cancels what the winners outran and hands a reader the kernel's slot.
class ComposeBenchWorldsHarnessTest < Minitest::Test
  include ComposeBenchHarness

  Worlds = E2E::ComposeBench::Worlds
  Rehearsal = E2E::ComposeBench::Rehearsal

  # EVERY OBJECTIVE HAS ITS WORLD, rooted in its eval's environment, and the six dimensions are the
  # frozen list: each variant is a set of dimensions spelled the second way, W0 spells none.
  def test_every_objective_declares_a_world_over_its_eval_environment
    Objectives::ALL.each do |objective|
      world = Worlds.for(objective)
      assert_equal objective.id, world.id
      assert File.directory?(world.environment), "#{objective.id}: #{world.environment}"
      assert_match(%r{/e2e/evals/tasks/compose-#{objective.slug}/environment\z}, world.environment)
    end
    assert_equal %w[no_match matched_path runner_detail record_format compound_command model_effect], Worlds::DIMENSIONS
    assert_empty Worlds::W0
    assert_equal [%w[no_match], %w[matched_path], %w[matched_path no_match]], Worlds.variants(%w[no_match matched_path])
    assert_empty Worlds.variants([]), "a draw touching nothing runs once, in W0"
  end

  # THE TOOLS ANSWER BY THE HARNESS'S CONTRACT: `grep` returns `file:line: text`, a miss is the
  # dimension `no_match` (nothing, or rho's sentence) and the file it names is `matched_path` (as
  # passed, or rho's basename); `read_file` returns the text and refuses a missing path.
  def test_grep_and_read_answer_by_the_contract_and_their_silences_are_dimensions
    grep = { "pattern" => "full_name", "path" => "app/models/team.rb" }
    miss = { "pattern" => "full_name", "path" => "app/models/user.rb" }
    open_run("O2") do |run|
      hit = run.call("grep", grep)
      assert_equal "completed", hit["status"]
      assert_equal "app/models/team.rb:5:   def full_name = \"\#{account.label} / \#{name}\"\napp/models/team.rb:7:   def to_s = full_name",
        hit["output"]
      assert_equal "", run.call("grep", miss)["output"]
      assert_equal %w[matched_path no_match], run.touched.sort
      assert run.call("read_file", { "path" => "app/models/nope.rb" })["is_error"]
      assert_includes run.call("read", { "path" => "app/models/team.rb" })["output"], "def to_s = full_name"
      assert run.call("grep", { "pattern" => "(", "path" => "app/models/team.rb" })["is_error"], "an invalid pattern"
    end
    open_run("O2", variant: %w[matched_path no_match]) do |run|
      assert run.call("grep", grep)["output"].start_with?("team.rb:5: ")
      assert_equal "No matches found in app/models/user.rb", run.call("grep", miss)["output"]
    end
  end

  # AN EDIT REPLACES EXACTLY ONE PASSAGE and the world remembers it: a later read sees the rename, an
  # edit whose passage is gone refuses, and the path is logged as edited.
  def test_an_edit_mutates_the_runs_copy_exactly_once
    edit = { "path" => "app/models/team.rb", "old_text" => "def full_name", "new_text" => "def display_name" }
    open_run("O2") do |run|
      done = run.call("edit", edit)
      assert_equal "Replaced one passage in app/models/team.rb.", done["output"]
      refute done["is_error"]
      assert_nil done["structured_content"]
      assert_includes run.call("grep", { "pattern" => "def display_name", "path" => "app/models/team.rb" })["output"],
        "app/models/team.rb:5:   def display_name"
      assert run.call("edit", edit)["is_error"], "the passage no longer occurs"
      assert run.call("edit", edit.merge("old_text" => "full_name", "new_text" => "full_name"))["is_error"], "no change"
      assert_equal ["app/models/team.rb"], run.edited
      assert_includes run.touched, "runner_detail", "a successful edit's envelope carries rho's detail in the variant"
    end
    open_run("O2", variant: %w[runner_detail]) do |run|
      assert_equal({ "replacements" => 1, "first_changed_line" => 5 }, run.call("edit", edit)["structured_content"])
    end
    environment = File.join(Worlds.for(Objectives.find("O2")).environment, "app/models/team.rb")
    assert_includes File.read(environment, encoding: "UTF-8"), "def full_name", "the environment itself is never edited"
  end

  # THE SHELL RUNS THE ENVIRONMENT'S OWN STAND-INS: `bin/srb tc` exits 1 — plain output in W0, rho's
  # exit line with `is_error` and `exit_status` under `runner_detail`; a compound command is refused
  # and logged in W0 and runs its head under `compound_command`; anything else is never run.
  def test_bash_runs_the_stand_ins_and_refuses_what_it_cannot_run
    open_run("O7b") do |run|
      srb = run.call("bash", { "command" => "bin/srb tc" })
      assert_equal "completed", srb["status"]
      refute srb["is_error"]
      assert_equal "app/models/order.rb:15: Method total does not exist on NilClass https://srb.help/7003\nErrors: 1", srb["output"]
      assert_nil srb["structured_content"]
      assert_includes run.touched, "runner_detail"
      compound = run.call("bash", { "command" => "bin/rubocop app || true" })
      assert compound["is_error"]
      assert_equal "bin/rubocop app || true: not run by the rehearsal world", compound["output"]
      assert run.call("bash", { "command" => "cat app/models/order.rb" })["is_error"]
      assert_equal ["bin/rubocop app || true", "cat app/models/order.rb"], run.unknown
      assert_includes run.touched, "compound_command"
      assert_includes run.call("bash", { "command" => "bin/rails test 2>&1" })["output"], "1 failures", "one trailing 2>&1 is dropped"
    end
    open_run("O7b", variant: %w[compound_command runner_detail]) do |run|
      srb = run.call("bash", { "command" => "bin/srb tc" })
      assert srb["is_error"]
      assert srb["output"].end_with?("Errors: 1\n\nCommand exited with code 1")
      assert_equal({ "exit_status" => 1 }, srb["structured_content"])
      assert_includes run.call("bash", { "command" => "bin/rubocop app || true" })["output"], "2 offenses detected"
      assert_empty run.unknown
    end
    open_run("O7") do |run|
      assert_equal "a|2026-09-01|q7f3k", run.call("bash", { "command" => "curl -s https://a.example/feed" })["output"],
        "the eval's own conversion: a fetch is `bin/fetch <name>`"
      assert_equal "b|2026-09-02|m2z9p", run.call("bash", { "command" => "sh bin/fetch b" })["output"]
    end
  end

  # ONLY A SHELL OPERATOR MAKES A COMMAND COMPOUND: quoted arguments reach the stand-in as the shell
  # hands them, in every world; a descriptor's redirection is an operator and never an argument, so the
  # variant runs the head's own words; a glob, a variable or anything else after the stand-in is no
  # command the rehearsal can run in any world, and reaches no dimension.
  def test_only_a_shell_operator_makes_a_command_compound
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.write(File.join(dir, "bin/rails"), "#!/bin/sh\necho \"$#: $*\"\n")
      world = Worlds.for(Objectives.find("O7b")).with(environment: dir)
      Worlds::Run.open(world: world, variant: Worlds::W0, tool_names: Tools::NAMES) do |run|
        assert_equal "2: test test/models/user_test.rb", run.call("bash", { "command" => 'bin/rails test "test/models/user_test.rb"' })["output"]
        assert_equal "1: app/models/user.rb", run.call("bash", { "command" => "bin/rails 'app/models/user.rb'" })["output"]
        assert_empty run.touched
        assert run.call("bash", { "command" => "bin/rails test app/*.rb" })["is_error"]
        assert_empty run.touched, "a glob is not a compound command"
        assert run.call("bash", { "command" => "bin/rails test 2>&1 || true" })["is_error"]
        assert_equal ["bin/rails test app/*.rb", "bin/rails test 2>&1 || true"], run.unknown
        assert_equal %w[compound_command], run.touched
      end
      Worlds::Run.open(world: world, variant: %w[compound_command], tool_names: Tools::NAMES) do |run|
        assert_equal "1: test", run.call("bash", { "command" => "bin/rails test 2>&1 || true" })["output"]
        assert_equal "1: test", run.call("bash", { "command" => "bin/rails test > out.txt" })["output"]
        assert run.call("bash", { "command" => "bin/rails test app/*.rb" })["is_error"], "a glob runs in no world"
        assert_equal ["bin/rails test app/*.rb"], run.unknown
      end
    end
  end

  # `probe_host` IS `bin/probe <host>`: the stand-in's own text, an unknown host refused.
  def test_probe_host_answers_the_stand_ins_text
    open_run("O3") do |run|
      assert_equal "bravo: 200 OK (2s)", run.call("probe_host", { "host" => "bravo" })["output"]
      assert_equal "alpha: 200 OK (6s)", run.call("probe_host", { "host" => "alpha" })["output"]
      assert run.call("probe_host", { "host" => "delta" })["is_error"]
      assert_empty run.touched
    end
  end

  # THE RACE CLOCK IS THE STAND-INS' OWN SLEEPS: bravo 2, charlie 4, alpha 6; the fetches 1, 4, 7.
  def test_durations_are_the_stand_ins_sleeps
    open_run("O3") do |run|
      assert_equal [6, 2, 4], %w[alpha bravo charlie].map { |host| run.duration("tool", { "name" => "probe_host", "input" => { "host" => host } }) }
      assert_equal 0, run.duration("model", { "prompt" => "x" })
    end
    open_run("O7") do |run|
      assert_equal [1, 4, 7], %w[a b c].map { |name| run.duration("tool", { "name" => "bash", "input" => { "command" => "curl -s https://#{name}.example/feed" } }) }
    end
  end

  # `until: 2` SELECTS THE FIRST TWO FINISHERS, bravo then charlie, and cancels alpha's probe, which
  # would have ended past the second winner: the reader's slot is bravo's envelope with both selected.
  def test_a_quorum_race_selects_its_first_finishers_and_cancels_the_rest
    rehearsed = rehearse("O3", <<~'JS')
      const race = g.parallel(["alpha", "bravo", "charlie"].map(h => g.tool({ name: "probe_host", input: { host: h } })), { until: 2 });
      g.script({ results: [race], script: "const r = results[0]; return { head: r.output, selected: r.selected.map(e => e.output) };" });
    JS
    assert_equal({ "head" => "bravo: 200 OK (2s)", "selected" => ["bravo: 200 OK (2s)", "charlie: 200 OK (4s)"] },
      rehearsed.run.returned.fetch("script-1"))
    assert_equal "canceled", rehearsed.run.envelope("tool-1")["status"]
    assert_equal %w[completed completed], %w[tool-2 tool-3].map { |key| rehearsed.run.envelope(key)["status"] }
  end

  # A RACE SETTLES OVER ITS EXITS, AS THE KERNEL'S JOIN DOES: a group in an arm is one exit per member,
  # so bravo wins alone where the arm's slower alpha would have lost it to charlie; a race nested in an
  # arm ends at its own winner, outrunning charlie; a quorum through a nesting hands its reader every
  # winner first finisher first; and a nested race its enclosing race outran is canceled.
  def test_a_race_settles_over_its_exits_and_a_nested_race_ends_at_its_winner
    probe = ->(host) { %(g.tool({ name: "probe_host", input: { host: "#{host}" } })) }
    read = 'g.script({ results: [race], script: "return results[0].selected.map(e => e.output);" });'
    grouped = rehearse("O3", "const race = g.parallel([[g.parallel([#{probe.("alpha")}, #{probe.("bravo")}])], #{probe.("charlie")}], { until: \"any\" });\n#{read}")
    assert_equal ["bravo: 200 OK (2s)"], grouped.run.returned.fetch("script-1")
    assert_equal %w[canceled completed canceled], %w[tool-1 tool-2 tool-3].map { |key| grouped.run.envelope(key)["status"] }
    nested = rehearse("O3", "const inner = g.parallel([#{probe.("alpha")}, #{probe.("bravo")}], { until: \"any\" });\n" \
                            "const race = g.parallel([[inner], #{probe.("charlie")}], { until: \"any\" });\n#{read}")
    assert_equal ["bravo: 200 OK (2s)"], nested.run.returned.fetch("script-1")
    assert_equal %w[canceled completed canceled], %w[tool-1 tool-2 tool-3].map { |key| nested.run.envelope(key)["status"] }
    quorum = rehearse("O3", "const inner = g.parallel([#{probe.("alpha")}, #{probe.("charlie")}], { until: \"any\" });\n" \
                            "const race = g.parallel([[inner], #{probe.("bravo")}], { until: 2 });\n#{read}")
    assert_equal ["bravo: 200 OK (2s)", "charlie: 200 OK (4s)"], quorum.run.returned.fetch("script-1")
    assert_equal %w[canceled completed completed], %w[tool-1 tool-2 tool-3].map { |key| quorum.run.envelope(key)["status"] }
    outran = rehearse("O3", "const inner = g.parallel([#{probe.("alpha")}], { until: \"any\" });\n" \
                            "const race = g.parallel([[inner], #{probe.("bravo")}], { until: \"any\" });\n#{read}")
    assert_equal ["bravo: 200 OK (2s)"], outran.run.returned.fetch("script-1")
    assert_equal "canceled", outran.run.status("parallel-1")
  end

  # A RACE THAT NOTHING WINS FAILS WITH THE KERNEL'S WORD: every arm ends in a stage that throws, so
  # no arm succeeds and none is pending — `join_starved` — and the reader's slot is the failure alone.
  # A winner that fails hands the race to the next finisher first: every arm ran.
  def test_a_starved_race_hands_its_reader_the_failure_alone
    rehearsed = rehearse("O3", <<~'JS')
      const race = g.parallel(["alpha", "bravo", "charlie"].map(h => {
        const probe = g.tool({ name: "probe_host", input: { host: h } });
        return [probe, g.script({ results: [probe], script: "throw new Error('no ' + results[0].output);" })];
      }), { until: "any" });
      g.script({ results: [race], script: "return results[0];" });
    JS
    slot = rehearsed.run.returned.fetch("script-4")
    assert_equal "failed", slot["status"]
    assert_equal "join_starved", slot.dig("error", "key")
    assert_equal [slot.except("selected")], slot["selected"]
    assert_equal %w[completed completed completed], %w[tool-1 tool-2 tool-3].map { |key| rehearsed.run.envelope(key)["status"] }
    assert_equal ["failed script_error"] * 3, %w[script-1 script-2 script-3].map { |key| rehearsed.run.stages.fetch(key) }
  end

  # A RESULT-READING STAGE THAT DOES NOT PARSE is the kernel's compose-time refusal: it stays in
  # `refused`, places nothing, and a reader naming it receives its failure envelope.
  def test_a_stage_that_does_not_parse_is_refused_and_its_reader_reads_the_failure
    rehearsed = rehearse("O3", <<~'JS')
      const probe = g.tool({ name: "probe_host", input: { host: "bravo" } });
      const broken = g.script({ results: [probe], script: "return results[0].output +;" });
      g.script({ results: [broken], script: "return { status: results[0].status, key: results[0].error.key };" });
    JS
    assert_equal ["script-1"], rehearsed.inlined.refused.map(&:key)
    assert_equal "failed script_syntax_error", rehearsed.run.stages.fetch("script-1")
    assert_equal({ "status" => "failed", "key" => "script_syntax_error" }, rehearsed.run.returned.fetch("script-2"))
  end

  # WHAT THE KERNEL'S STAGE RUN REFUSES AROUND THE EVALUATOR: a value the row store cannot hold is
  # `result_unstorable` (an exponent-form float; a non-finite number the evaluator refuses itself), and
  # results past the snapshot bound are `script_input_too_large` before the stage is evaluated.
  def test_the_kernels_stage_run_refusals_are_read_in_order
    assert_equal "failed result_unstorable", rehearse("O3", 'g.script({ script: "return 1.5e-10;" });').run.stages.fetch("script-1")
    assert_equal "failed script_error", rehearse("O3", 'g.script({ script: "return 1e400;" });').run.stages.fetch("script-1")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "big.txt"), "x" * (Nexus::SizeBounds.fetch(:snapshot_bound) + 1))
      world = Worlds.for(Objectives.find("O3")).with(environment: dir)
      built = evaluate(<<~'JS')
        const big = g.tool({ name: "read_file", input: { path: "big.txt" } });
        g.script({ results: [big], script: "return results[0].output.length;" });
      JS
      Worlds::Run.open(world: world, variant: Worlds::W0, tool_names: Tools::NAMES) do |run|
        Shape.inline(built.steps, tool_names: Tools::NAMES, world: run)
        assert_equal "failed script_input_too_large", run.stages.fetch("script-1")
      end
    end
  end

  # A MODEL ANSWERS ITS WORLD'S DECLARED TEXT, whatever it read: O7's is the record format, a sentence in
  # W0 and the three records as JSON under `record_format`; an editing model does the objective's task
  # on the run's files only under `model_effect`.
  def test_a_model_answers_declared_text_and_its_effect_is_a_dimension
    open_run("O7") do |run|
      assert_equal Worlds.for(Objectives.find("O7")).text, run.model({ "prompt" => "normalise a" })["output"]
      assert_equal %w[record_format], run.touched
    end
    open_run("O7", variant: %w[record_format]) do |run|
      assert_equal %w[a b c], JSON.parse(run.model({ "prompt" => "normalise a" })["output"]).map { |record| record["source"] }
    end
    open_run("O4") do |run|
      run.model({ "prompt" => "fix" })
      assert_includes run.call("bash", { "command" => "bin/rubocop app" })["output"], "2 offenses detected"
      assert_equal %w[model_effect], run.touched
    end
    open_run("O4", variant: %w[model_effect]) do |run|
      run.model({ "prompt" => "report", "tools" => [] })
      assert_includes run.call("bash", { "command" => "bin/rubocop app" })["output"], "2 offenses detected", "a model that cannot edit changes nothing"
      run.model({ "prompt" => "fix" })
      assert_includes run.call("bash", { "command" => "bin/rubocop app" })["output"], "no offenses detected"
    end
  end

  private

    def open_run(id, variant: Worlds::W0, &block)
      Worlds::Run.open(world: Worlds.for(Objectives.find(id)), variant: variant, tool_names: Tools::NAMES, &block)
    end

    def rehearse(id, script, variant: Worlds::W0)
      objective = Objectives.find(id)
      built = evaluate(script)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      scored = E2E::ComposeBench::Scoring.score_built(objective, built, tool_names: Tools::NAMES)
      Rehearsal.rehearse(objective, built, scored, tool_names: Tools::NAMES, variant: variant)
    end
end
