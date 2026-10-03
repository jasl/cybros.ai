require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "support/coding_task"
require "evals_drawings"
require "fileutils"
require "tmpdir"
require "open3"

# THE CORPUS LOADER, PROVED ON PAPER: the seed task loads with every field; a task missing a field,
# the canary, a known driver, an `Expected`, a verifier lambda is REFUSED BY NAME — an author reads
# what to add, never that something is wrong; the environment writes under a tmpdir; the
# verification runs against a project dir and answers `{pass, output}`. Pure Ruby: nothing here
# boots.
class EvalsCorpusTest < Minitest::Test
  include EvalsFixtureBench
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  SEED_DIR = File.join(E2E::Evals::Corpus::DIR, "shape-linear")

  def test_the_seed_task_loads_with_every_field
    task = CORPUS.find("shape-linear")
    assert_equal %w[shape rho.coding easy plain], [task.family, task.capability, task.difficulty, task.driver]
    assert_equal({}, task.flags)
    assert_equal "kernel", task.compaction
    refute_predicate task, :runner_home?
    assert_equal 600, task.deadline_seconds
    assert task.verification
    assert_empty task.restore
    assert_equal %w[strong floor], task.tiers
    assert task.on_tier?(:floor)
    assert_match(/shapes\.rb:\d+/, task.source)
    assert_equal BENCH.canary, task.canary
    assert task.match?("shape-*")
    assert task.match?("shape/shape-linear"), "a glob over family/name selects too (the container families' door)"
    refute task.match?("compose/*")
    assert_equal BENCH.canary, task.instruction.lines.last.strip, "the canary is the instruction's last line"
    assert_kind_of E2E::Evals::Expected, task.expected
    assert_kind_of Proc, task.verifier
    assert_equal 2, task.verifier.arity
    assert_equal [], task.turns
    assert_equal "approve_all", task.policy
    assert_equal [], task.models
    assert task.on_model?("fixture/strong")
    assert_includes CORPUS.select("shape-*").map(&:name), "shape-linear"
    assert_empty CORPUS.select("nothing-*")
    assert_raises(ArgumentError) { CORPUS.find("shape-missing") }
  end

  # The supported families include the workflow shapes, the compaction family and the exit ladder —
  # every task under a family named here, every family with at least one task, the counts pinned.
  FAMILIES = { "shape" => 5, "compose" => 9, "task" => 6, "compaction" => 4, "workflow" => 6, "exit" => 3,
               "approval" => 1, "until" => 1, "processes" => 1, "handoff" => 1, "memory" => 1, "ask" => 1,
               "spawn" => 2 }.freeze

  # THE RAKE TASK'S OWN LOAD: `rake evals` builds the run list from the corpus with only the bench,
  # the corpus and the plan required, before any lane loads the rest — so a task file that names a
  # reader at its top level must find it through the corpus itself, in a process that loaded nothing
  # else (this suite's own `require "support/evals"` would hide the gap).
  def test_the_corpus_loads_through_the_evals_rake_tasks_own_requires
    program = 'require_relative "support/evals/bench"; require_relative "support/evals/corpus"; ' \
              'require_relative "support/evals/plan"; require_relative "test/evals_fixture_bench"; ' \
              "puts E2E::Evals::Corpus.load_all(bench: EvalsFixtureBench.read).tasks.size"
    output, status = Open3.capture2e(Gem.ruby, "-e", program, chdir: File.expand_path("..", __dir__))
    assert status.success?, output
    assert_operator output.to_i, :>, 0
  end

  def test_the_corpus_holds_every_family_with_its_tasks
    assert_equal FAMILIES, CORPUS.tasks.map(&:family).tally
    assert_equal 41, CORPUS.tasks.size
    CORPUS.tasks.each do |task|
      assert_equal task.name, File.basename(task.dir)
      assert_kind_of E2E::Evals::Expected, task.expected
      assert_equal task.verification, !task.verifier.nil?, "#{task.name}: verification.rb present iff verification: true"
      assert_includes E2E::Evals::Corpus::DRIVERS, task.driver
      assert task.instruction.end_with?(BENCH.canary), "#{task.name}: the canary is the last line"
    end
  end

  # THE SCOUT'S FIXTURE (D6): eleven sources under lib/ whose names share no stem with the finders'
  # (`workflow-fan-out-finders`: a model that met one fixture guesses nothing of the other), five of
  # them defining a class with a `call` method and two of the six others holding a `def call` inside a
  # module — the near-miss a grep for the method lists. The five are the files the task's success
  # counts per delegate, and the hidden check passes on a review.md naming exactly them.
  def test_the_scout_fixture_hides_five_callers_among_eleven_names_the_finders_never_used
    scout = CORPUS.find("workflow-scout-then-fan")
    sources = scout.static_files.select { |path, _| path.start_with?("lib/") }
    assert_equal sources.size, scout.static_files.size, "the fixture is lib/ alone"
    stems = sources.keys.map { |path| File.basename(path, ".rb") }
    finders = CORPUS.find("workflow-fan-out-finders").static_files.keys.map { |path| File.basename(path, ".rb") }
    assert_equal 11, stems.size
    assert_equal %w[auth billing cache export import mailer search webhooks], finders.sort
    shared = stems.flat_map { |stem| [stem, *stem.split("_")] }.select { |word| finders.any? { |f| f.include?(word) || word.include?(f) } }
    assert_empty shared, "a scout name shares a stem with the finders'"

    defines = ->(opener) { sources.select { |_path, text| text.match?(/^#{opener} /) && text.match?(/^\s+def call\b/) }.keys.sort }
    callers = defines.("class")
    assert_equal 5, callers.size
    assert_equal 2, defines.("module").size, "the near-miss: a def call inside a module"
    green = scout.expected.verdict(EvalsDrawings::GREEN.fetch("workflow-scout-then-fan"))
    assert_equal callers, green.facts.fetch("per_file").keys.sort, "success counts the fixture's five"
    assert_equal callers, EvalsDrawings::SCOUT_CALLERS.map { |f| "lib/#{f}.rb" }, "the drawings list the fixture's five"

    Dir.mktmpdir("evals-scout") do |home|
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "p"), model: "m")
      project = scout.write_environment(home, "p", seed)
      review = ->(paths) { File.write(File.join(project.root, "review.md"), paths.map { |path| "#{path} — fine\n" }.join) }
      review.(callers)
      assert scout.verify(project, seed)["pass"], "exactly the five"
      review.(callers + ["lib/date_parse.rb"])
      refute scout.verify(project, seed)["pass"], "a module's def call is no class's"
      review.(callers.drop(1))
      refute scout.verify(project, seed)["pass"], "one short"
    end
  end

  # A task's model selector narrows its tier; a floor model cannot run a strong-only task.
  def test_models_narrows_a_tier_and_the_wall_tasks_are_strong_only
    long = CORPUS.find("compaction-wall-long").with(models: ["fixture/strong"])
    assert_equal %w[strong], long.tiers
    assert_equal ["fixture/strong"], long.models
    assert long.on_model?("fixture/strong")
    refute long.on_model?("fixture/second")
    assert_equal %w[strong], CORPUS.find("compaction-wall-kernel").tiers
    assert_empty CORPUS.find("compaction-wall-kernel").models
    selection = E2E::Evals::Selection.new(tasks_glob: "compaction-wall-*", models: BENCH.models, styles: ["nexus"], runs: 1,
      label: "x", runs_dir: "/tmp/x")
    corpus = CORPUS.with(tasks: [CORPUS.find("compaction-wall-kernel"), long])
    runs = E2E::Evals::Plan.build(corpus, BENCH, selection)
    assert_equal({ "compaction-wall-kernel" => 2, "compaction-wall-long" => 1 }, runs.map { |run| run.task.name }.tally)
    assert_equal ["fixture/strong"], runs.select { |run| run.task.name == "compaction-wall-long" }.map(&:model)
    refute_includes runs.map(&:model), "fixture/floor"
    bad = assert_raises(ArgumentError) { load_mutated { |front| front.sub("tiers: [strong, floor]", "tiers: [strong, floor]\nmodels: glm") } }
    assert_match(/models must be a list of model ids/, bad.message)
  end

  # Unknown drivers are refused by name. `spawn_reply` handles a detached child reply and is
  # distinct from the ordinary second-turn driver.
  def test_the_three_v2_drivers_are_known_and_a_stranger_is_still_refused
    assert_equal %w[settle_receipts memory_scope processes], E2E::Evals::Corpus::DRIVERS.last(3)
    assert_equal "spawn_reply", CORPUS.find("spawn-subagent-suite").driver
    assert_equal "plain", CORPUS.find("spawn-peer-relay").driver
    assert_equal %w[settle_receipts], CORPUS.select("workflow-*").map(&:driver).uniq
    assert_equal "settle_receipts", CORPUS.find("task-fan-five").driver,
      "a detached fan's merge is written by a turn a receipt woke: the run is read once the conversation is quiet"
    assert_equal "memory_scope", CORPUS.find("memory-user-scope").driver
    assert_equal "processes", CORPUS.find("processes-dev-server").driver
  end

  # A fixture file that opens with a shebang is written executable, so
  # `bin/rails test` and `bin/probe alpha` run by path.
  def test_a_shebang_fixture_file_is_written_executable
    Dir.mktmpdir("evals-exec") do |home|
      task = CORPUS.find("compose-race")
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "p"), model: "m")
      project = task.write_environment(home, "p", seed)
      assert File.executable?(File.join(project.root, "bin/probe")), "bin/probe is executable"
      output, status = project.run("bin/probe bravo")
      assert_predicate status, :success?, output
      assert_match(/bravo: 200 OK/, output)
    end
  end

  # compose-race-anon is compose-race with probes that name no host: the same instruction, the same
  # delays (bravo first), and an output line in which only the delay is left — what names the host
  # of a delivered result there is the envelope's `<call>` line alone. The bar, the conduct and the
  # facts are ONE file's (anon's expected file evaluates the race's), so the two cells read every
  # trace alike: a green one, a wrong winner, no compose call.
  def test_the_anon_race_is_the_race_with_probes_that_name_no_host
    race, anon = %w[compose-race compose-race-anon].map { |name| CORPUS.find(name) }
    assert_equal race.instruction, anon.instruction
    assert_equal race.expected.facts.keys, anon.expected.facts.keys
    assert_equal race.expected.conduct.keys, anon.expected.conduct.keys
    [EvalsDrawings::GREEN.fetch("compose-race"),
     EvalsDrawings::GREEN.fetch("compose-race").with_facts("reply" => "alpha won"),
     EvalsDrawings::RED.fetch("compose-race").first].each do |trace|
      assert_equal race.expected.verdict(trace), anon.expected.verdict(trace)
    end
    probes = [race, anon].map { |task| task.static_files.fetch("bin/probe") }
    assert_equal probes.first.scan(/(\w+)\) sleep (\d)/), probes.last.scan(/(\w+)\) sleep (\d)/)
    assert_equal ["200 OK (6s)", "200 OK (2s)", "200 OK (4s)"], probes.last.scan(/sleep \d; echo "([^"]*)"/).flatten
    %w[alpha bravo charlie].each { |host| assert_includes probes.first, "echo \"#{host}: 200 OK" }
  end

  # The exit ladder's fixtures are the corpus's, and the three live lanes
  # read them here (decision 13): exit-long's generator mints the vectors,
  # the server, the gate and the brief over the seed and writes the token
  # outside the project root.
  def test_the_exit_long_generator_writes_the_token_outside_the_root
    Dir.mktmpdir("evals-exit-long") do |home|
      task = CORPUS.find("exit-long")
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "codec"), model: "m")
      files = ENV.key?("E2E_EXIT_LONG_VECTORS") ? task.files(seed) : with_env("E2E_EXIT_LONG_VECTORS" => "3") { task.files(seed) }
      assert_equal "#{seed.secret}\n", File.read(File.join(home, "spec-seed"))
      assert_equal 3, files.keys.count { |path| path.start_with?("spec/vectors/vec-") } if files.key?("spec/vectors/vec-03.txt")
      %w[src/frame_codec.js test/frame_codec_test.rb test/spec_token_test.rb test/all.rb server/app.rb server/PORT check.sh PORT.md].each do |path|
        assert files.key?(path), "exit-long ships #{path}"
      end
      assert_equal "#{seed.port}\n", files.fetch("server/PORT")
      assert_includes files.fetch("check.sh"), File.join(home, "spec-seed")
      vector = files.fetch("spec/vectors/vec-01.txt")
      assert_match(/\Avector-\h{12} of vec-01\.txt\n/, vector)
      assert_equal 1, vector.lines.count { |line| line.start_with?("marker-") }
      refute_empty CORPUS.find("exit-small").static_files.fetch("test/cart_test.rb")
      assert_equal 13, CORPUS.find("exit-medium").static_files.size
    end
  end

  # ONE TEXT: the coding turn the two runner lanes give a real model, byte for byte, with the canary
  # line after it.
  def test_the_seed_instruction_is_the_coding_task_plus_the_canary
    task = CORPUS.find("shape-linear")
    assert_equal E2E::CODING_TASK, task.instruction.lines[0..-2].join.strip
  end

  def test_every_task_dir_carries_a_rationale_with_the_reading_a_red_section
    CORPUS.tasks.each do |task|
      rationale = File.read(File.join(task.dir, "RATIONALE.md"), encoding: Encoding::UTF_8)
      assert_includes rationale, "## Reading a red", "#{task.name}: RATIONALE.md ends with how to read a red"
      %w[lane bug model conduct kernel finding].each_slice(2) { |words| assert_includes rationale, words.join(" ") }
    end
  end

  def test_a_task_missing_a_field_is_refused_by_name
    error = assert_raises(ArgumentError) { load_mutated { |front| front.sub(/^tiers:.*\n/, "") } }
    assert_equal "evals task shape-linear: front-matter is missing tiers", error.message
  end

  def test_a_task_whose_last_line_is_not_the_canary_is_refused
    error = assert_raises(ArgumentError) { load_mutated(body: ->(body) { body.sub(BENCH.canary, "nothing to see") }) }
    assert_match(/the instruction's last line is not the canary/, error.message)
    other = "deadbeef-0000-4000-8000-000000000000"
    wrong_field = assert_raises(ArgumentError) { load_mutated { |front| front.sub(BENCH.canary, other) } }
    assert_match(/canary "#{other}" is not the bench's/, wrong_field.message)
  end

  def test_an_unknown_driver_a_bad_tier_and_a_bad_flag_are_refused
    error = assert_raises(ArgumentError) { load_mutated { |front| front.sub("driver: plain", "driver: teleport") } }
    assert_match(/driver "teleport" is not one of plain, answer_ask/, error.message)
    tier = assert_raises(ArgumentError) { load_mutated { |front| front.sub("tiers: [strong, floor]", "tiers: [weak]") } }
    assert_match(/tiers must be a non-empty subset of strong, floor/, tier.message)
    flag = assert_raises(ArgumentError) { load_mutated { |front| front.sub("flags: {}", "flags: { model: x }") } }
    assert_match(/flags must be a mapping of approval, until, attempts, compose/, flag.message)
    daemon = assert_raises(ArgumentError) { load_mutated { |front| front.sub("compaction: kernel", "compaction: prune") } }
    assert_match(/daemon.compaction must be one of kernel\|delegate/, daemon.message)
    name = assert_raises(ArgumentError) { load_mutated { |front| front.sub("name: shape-linear", "name: shape-other") } }
    assert_match(/name "shape-other" is not the directory's "shape-linear"/, name.message)
  end

  # EVERY SHAPE REFUSAL, BY NAME: a field written in the wrong shape — a scalar where a list goes, a
  # list where a mapping goes, a number spelled as a String or a Float, nothing at all — is refused
  # with the field's own sentence, never read by a guess.
  def test_a_front_matter_field_of_the_wrong_shape_is_refused_by_name
    {
      ["tags: [gallery, coding, linear]", "tags: gallery"] => "tags must be a list",
      ["flags: {}", "flags: [approval]"] => "flags must be a mapping of approval, until, attempts, compose",
      ["daemon: { compaction: kernel }", "daemon: kernel"] => "daemon must be a mapping of compaction, runner_home",
      ["daemon: { compaction: kernel }", "daemon: { compaction: kernel, extra: 1 }"] => "daemon must be a mapping of compaction, runner_home",
      ["deadline_seconds: 600", "deadline_seconds: 600.0"] => "deadline_seconds must be a positive integer",
      ["deadline_seconds: 600", "deadline_seconds: '600'"] => "deadline_seconds must be a positive integer",
      ["deadline_seconds: 600", "deadline_seconds: 0"] => "deadline_seconds must be a positive integer",
      ["deadline_seconds: 600", "deadline_seconds: ~"] => "deadline_seconds must be a positive integer",
      ["deadline_seconds: 600", "deadline_seconds: ten"] => "deadline_seconds must be a positive integer",
      ["restore: []", "restore: fizzbuzz.rb"] => "restore must be a list of paths",
      ["tiers: [strong, floor]", "tiers: strong"] => "tiers must be a non-empty subset of strong, floor",
      ["tiers: [strong, floor]", "tiers: []"] => "tiers must be a non-empty subset of strong, floor",
      ["tiers: [strong, floor]", "tiers: [strong, floor]\nturns: hello"] => "turns must be a list of strings",
      ["tiers: [strong, floor]", "tiers: [strong, floor]\nturns: [1]"] => "turns must be a list of strings",
      ["tiers: [strong, floor]", "tiers: [strong, floor]\nmodels: [7]"] => "models must be a list of model ids",
    }.each do |(from, to), why|
      error = assert_raises(ArgumentError) { load_mutated { |front| front.sub(from, to) } }
      assert_equal "evals task shape-linear: #{why}", error.message, to
    end
    mapping = assert_raises(ArgumentError) { load_mutated { |_front| "- name\n- family" } }
    assert_equal "evals task shape-linear: the front-matter is not a mapping", mapping.message
  end

  # AN EVALUATED FILE THAT IS NOT WHAT IT MUST BE is refused by its file's sentence: a Hash, an empty
  # file, a lambda over the wrong number of arguments.
  def test_an_environment_or_a_verifier_of_the_wrong_kind_is_refused_by_name
    { "environment.rb" => ["environment.rb must evaluate to a lambda over a Seed", ["->() { {} }\n", "->(seed, other) { {} }\n"]],
      "verification.rb" => ["verification.rb must evaluate to a lambda over (project, seed)", ["->(a, b, c) { {} }\n"]] }
      .each do |file, (why, arities)|
        ["{ \"fizzbuzz.rb\" => \"puts 1\" }\n", "\n", *arities].each do |source|
          error = assert_raises(ArgumentError) { load_mutated(files: { file => source }) }
          assert_equal "evals task shape-linear: #{why}", error.message, "#{file}: #{source.inspect}"
        end
      end
    keywords = assert_raises(ArgumentError) { load_mutated(files: { "expected.rb" => "{ reach: nil, success: nil }\n" }) }
    assert_equal "evals task shape-linear: expected.rb must evaluate to an E2E::Evals::Expected, got Hash", keywords.message
  end

  def test_an_expected_that_is_not_an_expected_and_a_verifier_that_is_not_a_lambda_are_refused
    error = assert_raises(ArgumentError) { load_mutated(files: { "expected.rb" => "42\n" }) }
    assert_match(/expected\.rb must evaluate to an E2E::Evals::Expected, got Integer/, error.message)
    verifier = assert_raises(ArgumentError) { load_mutated(files: { "verification.rb" => "->(project) { {} }\n" }) }
    assert_match(/verification\.rb must evaluate to a lambda over \(project, seed\)/, verifier.message)
    missing = assert_raises(ArgumentError) { load_mutated(files: { "expected.rb" => nil }) }
    assert_equal "evals task shape-linear: expected.rb is missing", missing.message
  end

  def test_a_task_without_verification_needs_no_verifier
    task = load_mutated(files: { "verification.rb" => nil }) { |front| front.sub("verification: true", "verification: false") }
    refute task.verification
    assert_nil task.verifier
  end

  # A static `environment/` directory and the `environment.rb` lambda
  # merge into one file set, written under the home as a FixtureProject.
  def test_the_environment_writes_under_a_tmpdir
    Dir.mktmpdir("evals-env") do |home|
      task = load_mutated(files: { "environment/README.md" => "static\n", "environment/lib/a.rb" => "A = 1\n",
                                   "environment.rb" => "->(seed) { { \"seed.txt\" => \"\#{seed.secret}\\n\" } }\n" })
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "p"), model: "m")
      assert_equal %w[README.md lib/a.rb seed.txt], task.files(seed).keys.sort
      project = task.write_environment(home, "p", seed)
      assert_equal File.join(home, "p"), project.root
      assert_equal "A = 1\n", File.read(File.join(home, "p", "lib", "a.rb"), encoding: Encoding::UTF_8)
      assert_equal "#{seed.secret}\n", File.read(File.join(home, "p", "seed.txt"), encoding: Encoding::UTF_8)
      assert_predicate seed.port, :positive?
      assert_equal 16, seed.secret.length
      # THE EMPTY ENVIRONMENT (the seed's own `->(_seed) { {} }`) still gets
      # its directory: rho's `/environment` refuses a root that is not one.
      empty = CORPUS.find("shape-linear").write_environment(home, "empty", seed)
      assert_equal({}, empty.files)
      assert File.directory?(empty.root), "an empty environment must still create #{empty.root}"
    end
  end

  # EVERY RUN'S GROUND IS ITS OWN (the v11 bench's shared directory: a model's run #N wrote into
  # the directory an earlier model's run #N had left, and read its `results/` and `bin/` as the
  # fixture's): a directory that exists is refused whole, never written over.
  def test_the_environment_refuses_a_directory_an_earlier_run_left
    Dir.mktmpdir("evals-env") do |home|
      task = CORPUS.find("workflow-loop-until-dry")
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "p"), model: "m")
      project = task.write_environment(home, "p", seed)
      File.write(File.join(project.root, "results", "item-01.txt"), "14\n")
      refused = assert_raises(Errno::EEXIST) { task.write_environment(home, "p", seed) }
      assert_includes refused.message, project.root
      assert_equal "14\n", File.read(File.join(project.root, "results", "item-01.txt"), encoding: Encoding::UTF_8),
        "the refusal writes nothing"
    end
  end

  # The verification restores the graded surfaces from the fixture first,
  # then judges the program's own output; a raise is a red with the error.
  def test_the_verification_restores_then_judges_the_program
    Dir.mktmpdir("evals-verify") do |home|
      task = load_mutated { |front| front.sub("restore: []", "restore: [SPEC.md]") }
        .with(static_files: { "SPEC.md" => "the spec\n" })
      seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "p"), model: "m")
      project = task.write_environment(home, "p", seed)
      File.write(File.join(project.root, "SPEC.md"), "edited by the model\n")
      assert_equal({ "pass" => false, "output" => "fizzbuzz.rb was never written" }, task.verify(project, seed))
      assert_equal "the spec\n", File.read(File.join(project.root, "SPEC.md"), encoding: Encoding::UTF_8), "restored first"

      File.write(File.join(project.root, "fizzbuzz.rb"), <<~RUBY)
        def fizzbuzz(n)
          return "FizzBuzz" if (n % 15).zero?
          return "Fizz" if (n % 3).zero?
          return "Buzz" if (n % 5).zero?

          n.to_s
        end
        (1..15).each { |n| puts fizzbuzz(n) } if __FILE__ == $PROGRAM_NAME
      RUBY
      verdict = task.verify(project, seed)
      assert verdict["pass"], verdict.inspect
      assert_match(/\A1\n2\nFizz\n4\nBuzz/, verdict["output"])

      File.write(File.join(project.root, "fizzbuzz.rb"), "puts 'nope'\n")
      refute task.verify(project, seed)["pass"]
      raising = task.with(verifier: ->(_project, _seed) { raise "boom" })
      assert_equal({ "pass" => false, "output" => "RuntimeError: boom" }, raising.verify(project, seed))
    end
  end

  private

    def with_env(pairs)
      saved = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      pairs.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    # A copy of the seed task under a tmpdir with the front-matter, the
    # body or a file changed, loaded through the one loader.
    def load_mutated(body: nil, files: {})
      Dir.mktmpdir("evals-corpus") do |root|
        dir = File.join(root, "shape-linear")
        FileUtils.cp_r(SEED_DIR, dir)
        source = File.read(File.join(dir, "instruction.md"), encoding: Encoding::UTF_8)
        match = E2E::Evals::Corpus::FRONT_MATTER.match(source)
        front = block_given? ? yield(match[:yaml]) : match[:yaml]
        text = body ? body.call(match[:body]) : match[:body]
        File.write(File.join(dir, "instruction.md"), "---\n#{front}\n---\n#{text}")
        files.each do |path, contents|
          full = File.join(dir, path)
          if contents.nil?
            File.delete(full)
          else
            FileUtils.mkdir_p(File.dirname(full))
            File.write(full, contents)
          end
        end
        E2E::Evals::Corpus.load_task(dir, canary: BENCH.canary)
      end
    end
end
