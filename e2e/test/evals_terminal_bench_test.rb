require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "fileutils"
require "json"
require "tmpdir"

# THE TERMINAL-BENCH LOADER, PROVED ON THE SAMPLE FIXTURE: harbor's flat form — `instruction.md`,
# `task.toml` in the pinned 1.0 form (no `[task]` table) AND the 1.1 form (`schema_version`, a
# `[task].name` PREFIXED `terminal-bench/<dir>`), `tests/test.sh` — loads into a `terminal-bench`
# task whose deadline is THEIRS, whose instruction is their bytes verbatim, whose predicate reads no
# reach (`reached: nil`), whose default and optional models are fixture policy and whose n is the
# cell's; what is missing or wrong is refused by name.
# The verify shape — the tests copied in, `test.sh` as root in the workdir, `reward.txt` read off
# the host — is pinned over a RECORDING docker: `1`, `0`, absent, garbage, a failed copy, a verifier
# past its timeout. The real checkout's 21 load when E2E_EVALS_TB_CORPUS names it. Pure Ruby:
# nothing here boots or builds.
class EvalsTerminalBenchTest < Minitest::Test
  include EvalsFixtureBench
  T = E2E::Evals::TerminalBench
  K = E2E::Evals::Docker
  FIXTURE = File.expand_path("../support/fixtures/terminal_bench", __dir__)
  BENCH = EvalsFixtureBench.read
  FLOOR_MODEL = "fixture/floor".freeze
  OPTIONAL_MODEL = "fixture/second".freeze
  OTHER_OPTIONAL_MODEL = "fixture/strong".freeze
  Status = Data.define(:ok) do
    def success? = ok
    def exitstatus = ok ? 0 : 1
  end
  # A process that exited with its own code, as the docker port's Process::Status reports it.
  Exited = Data.define(:code) do
    def success? = code.zero?
    def exitstatus = code
  end

  def test_the_sample_corpus_loads_in_harbor_form
    corpus = T.load(FIXTURE, bench: BENCH)
    assert_equal %w[alpha-one beta-two], corpus.names
    task = corpus.find("alpha-one")
    assert_equal %w[terminal-bench terminal-bench.alpha-one plain medium], [task.family, task.capability, task.driver, task.difficulty]
    assert_equal "example.invalid/alpha-one:20251031", task.image
    assert_equal 900, task.deadline_seconds, "the deadline is THEIRS ([agent].timeout_sec), never the bench's 600"
    assert_equal 900, task.verifier_timeout_sec
    assert_equal File.read(File.join(FIXTURE, "alpha-one", "instruction.md"), encoding: Encoding::UTF_8), task.instruction,
      "the instruction is their bytes verbatim — no canary appended, nothing stripped"
    assert task.verification
    assert task.runner_home?
    assert_equal({}, task.flags)
    assert_equal "kernel", task.compaction
    assert_empty task.restore
    assert_empty task.turns
    assert_equal %w[strong floor], task.tiers
    assert task.on_tier?(:floor)
    assert task.on_tier?("strong")
    assert_equal File.join(FIXTURE, "alpha-one", "tests"), task.tests_dir
    assert_nil task.workdir, "the workdir is read off the pulled base, never assumed"
    assert_nil task.tests_mount, "the hidden check is copied in at verify time, never mounted for the turn"
    assert_equal "0", task.container_user
    assert_equal K::APP_OWNER_BASE, K.app_owner_for(container_user: task.container_user),
      "the tree keeps harbor's owner: git as root refuses a uid-1000 repository (H-1)"
    assert_equal "rho-evals-example.invalid-alpha-one-20251031-app-owner-base",
      K.tag_for_base(task.image, app_owner: K.app_owner_for(container_user: task.container_user)), "the family's tag names its recipe"
    assert_nil task.prepare(nil)
    assert_equal ["alpha-one"], corpus.select("alpha-*").map(&:name)
    assert_equal %w[alpha-one beta-two], corpus.select("terminal-bench/*").map(&:name), "the family selects as family/*: its names share no prefix"
    assert_empty corpus.select("shape/*")
    assert_raises(ArgumentError) { corpus.find("nope") }

    # The 1.1 form: `schema_version`, the prefixed [task].name, their own numbers.
    beta = corpus.find("beta-two")
    assert_equal [1200, 1200, "hard", "example.invalid/beta-two:20251031"], [beta.deadline_seconds, beta.verifier_timeout_sec, beta.difficulty, beta.image]
  end

  # NO REACH DIMENSION: the verdict reads nil on both predicate columns —
  # "not read", never a red — and task pass is the one number.
  def test_the_predicate_reads_no_reach
    task = T.load(FIXTURE, bench: BENCH).find("alpha-one")
    verdict = task.expected.verdict(E2E::Evals::Trace.empty)
    assert_nil verdict.reached
    assert_nil verdict.succeeded
    assert_nil verdict.reason
    assert_predicate verdict, :conduct_ok?
    assert verdict.work_survived?(true)
    refute verdict.work_survived?(false)
    refute verdict.work_survived?(nil)
    assert_same T::NO_REACH, task.expected
  end

  # The plan reads default and optional model cells from bench.yml. Defaults need no explicit model
  # selector; optional models do, and each cell limits the requested sample count.
  def test_the_models_are_the_benchs_two_cells_and_the_cells_cap_n
    task = T.load(FIXTURE, bench: BENCH).find("alpha-one")
    assert_equal [FLOOR_MODEL, OPTIONAL_MODEL, OTHER_OPTIONAL_MODEL], task.models, "the default cell, then the optional cell's two rows"
    assert task.on_model?(FLOOR_MODEL)
    refute task.on_model?(OPTIONAL_MODEL), "the optional cell's model is off the default"
    assert task.optional_model?(OPTIONAL_MODEL)
    refute task.on_model?(OTHER_OPTIONAL_MODEL)
    assert task.optional_model?(OTHER_OPTIONAL_MODEL), "the other model is admitted by the optional cell"
    assert_equal 3, task.runs_for(FLOOR_MODEL, 3), "the floor's cell is n=3 under runs_per_task 3"
    assert_equal 1, task.runs_for(FLOOR_MODEL, 1), "E2E_EVALS_RUNS narrows below the cell"
    assert_equal 3, task.runs_for(OPTIONAL_MODEL, 3), "the optional cell is n=3"
    assert_equal 3, task.runs_for(OTHER_OPTIONAL_MODEL, 3), "for both its rows"

    corpus = E2E::Evals::Corpus.load_all(bench: BENCH, env: { T::ENV_CORPUS => FIXTURE })
    assert_equal 30 + 2, corpus.tasks.size
    assert_includes corpus.families, "terminal-bench"
    assert_equal 30, E2E::Evals::Corpus.load_all(bench: BENCH, env: {}).tasks.size, "unset, the family is absent: no rake evals[*] becomes docker-bound by accident"

    whole = E2E::Evals::Plan.build(corpus, BENCH, BENCH.subset({ "E2E_EVALS_TASKS" => "alpha-*" }, today: Date.new(2026, 9, 15)))
    assert_equal [[FLOOR_MODEL, 1], [FLOOR_MODEL, 2], [FLOOR_MODEL, 3]], whole.map { |run| [run.model, run.index] }, "the whole bench selects the floor's cell alone, n=3"
    named = E2E::Evals::Plan.build(corpus, BENCH, BENCH.subset({ "E2E_EVALS_TASKS" => "alpha-*", "E2E_EVALS_MODELS" => OPTIONAL_MODEL }, today: Date.new(2026, 9, 15)))
    assert_equal [[OPTIONAL_MODEL, 1], [OPTIONAL_MODEL, 2], [OPTIONAL_MODEL, 3]], named.map { |run| [run.model, run.index] }, "the optional cell runs when named, n=3"
    other = E2E::Evals::Plan.build(corpus, BENCH, BENCH.subset({ "E2E_EVALS_TASKS" => "alpha-*", "E2E_EVALS_MODELS" => OTHER_OPTIONAL_MODEL }, today: Date.new(2026, 9, 15)))
    assert_equal [[OTHER_OPTIONAL_MODEL, 1], [OTHER_OPTIONAL_MODEL, 2], [OTHER_OPTIONAL_MODEL, 3]], other.map { |run| [run.model, run.index] }, "the optional cell's second row, the same n"

    configuration = E2E::Evals::Plan.groups(whole).keys.first
    assert_equal "kernel__nexus__runner__example.invalid_alpha-one_20251031", configuration.slug, "the image is a member of the configuration"
    assert_equal "example.invalid/alpha-one:20251031", configuration.image
    assert_predicate configuration, :container?
    assert_equal 3 * 2 * 900 + 900 + E2E::Evals::Plan::IMAGE_BUILD_SLACK_SECONDS, E2E::Evals::Plan.journey_seconds(whole),
      "one build's slack per distinct image"
    assert_in_delta 20.0, BENCH.cost_stop_usd_for(task.name, family: task.family), 0.001, "the family's stop from THEIR max"
  end

  # THE bench CHECKOUT, when named: the 21 frozen names, their deadlines
  # (Σ 20 100 s per pass), their bases, at the pinned commit.
  def test_the_frozen_names_load_from_the_pinned_checkout_when_named
    dir = ENV[T::ENV_CORPUS].to_s
    skip "#{T::ENV_CORPUS} names no manual dataset checkout" if dir.empty?

    bench = E2E::Evals::Bench.read

    corpus = T.load(dir, bench: bench)
    assert_equal 21, corpus.tasks.size
    assert_equal bench.terminal_bench_names, corpus.names
    assert_equal 20_100, corpus.tasks.sum(&:deadline_seconds), "their timeouts: 17 × 900, 2 × 1200, 1 × 1800, 1 × 600"
    assert_equal({ 600 => 1, 900 => 17, 1200 => 2, 1800 => 1 }, corpus.tasks.map(&:deadline_seconds).tally.sort.to_h)
    corpus.tasks.each do |task|
      assert_equal "alexgshaw/#{task.name}:20251031", task.image
      assert_equal task.deadline_seconds, task.verifier_timeout_sec, "#{task.name}: [verifier].timeout_sec equals [agent].timeout_sec on all 21"
      assert_equal "medium", task.difficulty, "#{task.name}: a fact column, every one medium"
      assert_path_exists File.join(task.tests_dir, "test_outputs.py")
    end
    head = `git -C #{dir} rev-parse HEAD 2>/dev/null`.strip
    assert_equal bench.terminal_bench.fetch("commit"), head, "the checkout is at the registry's pinned commit" unless head.empty?
  end

  def test_what_is_missing_or_wrong_is_refused_by_name
    Dir.mktmpdir("evals-tb") do |root|
      FileUtils.cp_r(FIXTURE, root)
      corpus = File.join(root, "terminal_bench")
      task = File.join(corpus, "alpha-one")

      File.rename(File.join(task, "instruction.md"), File.join(task, "instruction.md.away"))
      assert_match(/task alpha-one: instruction\.md is missing/, refusal(corpus))
      File.rename(File.join(task, "instruction.md.away"), File.join(task, "instruction.md"))
      with_file(File.join(task, "instruction.md"), "\n\n") { assert_match(/instruction\.md is empty/, refusal(corpus)) }

      File.rename(File.join(task, "tests", "test.sh"), File.join(task, "tests", "away.sh"))
      assert_match(%r{tests/test\.sh is missing}, refusal(corpus))
      File.rename(File.join(task, "tests", "away.sh"), File.join(task, "tests", "test.sh"))

      toml = File.join(task, "task.toml")
      with_file(toml, "version = [\n") { assert_match(/task\.toml does not parse: /, refusal(corpus)) }
      rewrite(toml, /^docker_image = .*\n/, "") { assert_match(/\[environment\]\.docker_image is missing/, refusal(corpus)) }
      rewrite(toml, /^docker_image = .*$/, "docker_image = 7") { assert_match(/\[environment\]\.docker_image is missing/, refusal(corpus)) }
      rewrite(toml, /^docker_image = .*$/, "docker_image = \"  \"") { assert_match(/\[environment\]\.docker_image is missing/, refusal(corpus)) }
      rewrite(toml, /^\[agent\]\ntimeout_sec = 900\.0\n/, "[agent]\ntimeout_sec = true\n") { assert_match(/\[agent\]\.timeout_sec must be a positive number/, refusal(corpus)) }
      rewrite(toml, /^\[agent\]\ntimeout_sec = 900\.0\n/, "[agent]\ntimeout_sec = 900\n") do
        assert_equal 900, E2E::Evals::TerminalBench.load(corpus, bench: BENCH).find("alpha-one").deadline_seconds, "an integer timeout is a number"
      end
      rewrite(toml, /^\[agent\]\ntimeout_sec = 900\.0\n/, "[agent]\ntimeout_sec = 0.0\n") { assert_match(/\[agent\]\.timeout_sec must be a positive number/, refusal(corpus)) }
      rewrite(toml, /^\[agent\]\ntimeout_sec = 900\.0\n/, "[agent]\n") { assert_match(/\[agent\]\.timeout_sec must be a positive number/, refusal(corpus)) }
      rewrite(toml, /^\[verifier\]\ntimeout_sec = 900\.0\n/, "[verifier]\ntimeout_sec = \"900\"\n") { assert_match(/\[verifier\]\.timeout_sec must be a positive number/, refusal(corpus)) }
      rewrite(toml, /^version = "1\.0"\n/, "version = \"0.9\"\n") { assert_match(/version "0\.9" is not one of 1\.0\|1\.1/, refusal(corpus)) }
      rewrite(toml, /^version = "1\.0"\n/, "") { assert_match(/version "" is not one of/, refusal(corpus)) }
      rewrite(toml, /^difficulty = "medium"\n/, "difficulty = \"brutal\"\n") { assert_match(/\[metadata\]\.difficulty "brutal" is not one of easy\|medium\|hard/, refusal(corpus)) }

      beta = File.join(corpus, "beta-two", "task.toml")
      rewrite(beta, /^name = "terminal-bench\/beta-two"\n/, "name = \"beta-two\"\n") do
        assert_match(%r{task beta-two: \[task\]\.name "beta-two" is not "terminal-bench/beta-two"}, refusal(corpus))
      end

      FileUtils.rm_rf(File.join(corpus, "beta-two"))
      assert_match(/lacks beta-two \(the checkout must be sample@1 at 11111111/, refusal(corpus))
      assert_match(/is not a directory/, refusal(File.join(root, "nowhere")))
      assert_match(/names no task/, refusal(corpus, bench: BENCH.with(document: BENCH.document.merge("terminal_bench" => BENCH.terminal_bench.merge("tasks" => [])))))
    end
  end

  # THE VERIFY SHAPE over a recording docker: the tests copied in, `test.sh`
  # as root in the workdir with root's HOME, the reward read off the host —
  # `1` passes, `0` fails, absent and garbage are red BY NAME, a failed copy
  # is red with its output, a verifier past its timeout is red and never a
  # raise. `verify_in` is the task's door to it.
  def test_verify_in_reads_the_reward_off_the_host
    Dir.mktmpdir("evals-tb-verify") do |root|
      home = File.join(root, "home")
      logs = File.join(root, "verifier")
      FileUtils.mkdir_p([home, logs])
      task = T.load(FIXTURE, bench: BENCH).find("alpha-one")
      calls = []
      reward = "1\n"
      docker = lambda do |argv|
        calls << argv
        File.write(K.reward_path(logs), reward) if reward && argv.include?("bash")
        ["ran\n", Status.new(ok: true)]
      end
      daemon = K::Daemon.new(base_url: "http://127.0.0.1:3999", home: home, name: "c", port: 47001, tag: "rho-evals-x", logs_dir: logs,
        user: "0", docker: docker)

      verdict = task.verify_in(daemon, workdir: "/app")
      assert_equal({ "pass" => true, "reward" => 1.0 }, verdict.slice("pass", "reward"))
      assert_equal ["docker", "cp", task.tests_dir, "c:/tests"], calls[-2], "the hidden check is copied in AFTER the turn"
      assert_equal %w[docker exec -w /app -u 0 -e HOME=/root c bash /tests/test.sh], calls.last
      assert_includes verdict["output"], "$ bash /tests/test.sh (exit 0)"
      assert_includes verdict["output"], "reward.txt: 1.0"

      reward = "0\n"
      assert_equal false, task.verify_in(daemon, workdir: "/app")["pass"]
      exited = ->(argv) { [argv.include?("bash") ? "1 failed\n" : "", argv.include?("bash") ? Exited.new(code: 2) : Status.new(ok: true)] }
      coded = K::Daemon.new(base_url: "http://127.0.0.1:1", home: home, name: "c", port: 1, tag: "t", logs_dir: logs, docker: exited)
      assert_includes coded.verify_reward!(tests_dir: task.tests_dir, workdir: "/app")["output"], "$ bash /tests/test.sh (exit 2)",
        "the transcript names the verifier's own exit code"
      reward = "banana"
      verdict = task.verify_in(daemon, workdir: "/app/dclm")
      assert_equal false, verdict["pass"]
      assert_nil verdict["reward"]
      assert_includes verdict["output"], 'reward.txt holds "banana", not a number'
      assert_equal %w[docker exec -w /app/dclm -u 0 -e HOME=/root c bash /tests/test.sh], calls.last, "the workdir is the image's"
      reward = nil
      File.delete(K.reward_path(logs))
      verdict = task.verify_in(daemon, workdir: "/app")
      assert_equal false, verdict["pass"]
      assert_includes verdict["output"], "no /logs/verifier/reward.txt was written"

      failing_copy = ->(argv) { [argv[1] == "cp" ? "no such container\n" : "", Status.new(ok: argv[1] != "cp")] }
      cannot = K::Daemon.new(base_url: "http://127.0.0.1:1", home: home, name: "c", port: 1, tag: "t", logs_dir: logs, docker: failing_copy)
      verdict = task.verify_in(cannot, workdir: "/app")
      assert_equal false, verdict["pass"]
      assert_includes verdict["output"], "no such container"

      slow = lambda do |argv|
        sleep 0.3 if argv.include?("bash")
        ["", Status.new(ok: true)]
      end
      late = K::Daemon.new(base_url: "http://127.0.0.1:1", home: home, name: "c", port: 1, tag: "t", logs_dir: logs, docker: slow)
      verdict = late.verify_reward!(tests_dir: task.tests_dir, workdir: "/app", timeout: 0.05)
      assert_equal false, verdict["pass"]
      assert_includes verdict["output"], "ran past 0.05 s"

      unmounted = K::Daemon.new(base_url: "http://127.0.0.1:1", home: home, name: "c", port: 1, tag: "t", docker: docker)
      assert_match(/logs_dir/, task.verify_in(unmounted, workdir: "/app")["output"], "no host dir at /logs/verifier is a red with the reason")
    end
  end

  private

    def refusal(corpus, bench: BENCH)
      T.load(corpus, bench: bench)
      flunk "loaded a corpus that should have been refused"
    rescue ArgumentError => error
      error.message
    end

    def with_file(path, contents)
      original = File.read(path, encoding: Encoding::UTF_8)
      File.write(path, contents)
      yield
    ensure
      File.write(path, original)
    end

    def rewrite(path, from, to, &block)
      original = File.read(path, encoding: Encoding::UTF_8)
      assert_match from, original, "the fixture line to rewrite exists"
      with_file(path, original.sub(from, to), &block)
    end
end
