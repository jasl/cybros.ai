require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "tmpdir"

# EVERY HIDDEN CHECK AND EVERY PREDICATE, CALLABLE BEFORE A PAID RUN (step
# 12a's pin, 2026-09-11 — the matrix runs unattended, so a verification
# that raises on the project the loader writes, or a predicate that raises
# on a thin trace, must fail here and not after an hour of model time):
# for each task with `verification: true`, the environment is written
# under a tmpdir THROUGH THE CORPUS LOADER (the generators at their smoke
# sizes) and the lambda itself — not `Task#verify`, whose rescue would
# spell a raise as a red — is called against it, untouched: it answers
# `{"pass" => bool, "output" => String}`, and the untouched environment is
# RED (a check the fixture already passes measures nothing). For every
# task, `expected.rb`'s four lambdas are called over `Trace.empty` — the
# trace a stopped run salvages when no round completed: reach answers a
# String naming the missing structure, success answers a String too
# (except the five named below, whose success IS an absence), each
# conduct fact answers true or a String, each column answers without
# raising. Pure Ruby: nothing here boots.
class EvalsVerificationsTest < Minitest::Test
  include EvalsFixtureBench
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  EMPTY = E2E::Evals::Trace.empty
  # The generators' smoke sizes: the pin proves the lambdas callable over
  # what the loader writes, never the wall — the bench sizes (56 vectors,
  # 60 and 18 files) are the paid lane's.
  SMOKE_SIZES = { "E2E_EXIT_LONG_VECTORS" => "3", "E2E_LONG_FILES" => "3", "E2E_WALL_KERNEL_FILES" => "2" }.freeze
  # SUCCESS BY ABSENCE: the two over-reach controls succeed when NO graph
  # verb was called, and the three workflow shapes when no loop was left
  # incomplete (the scout also when no name was guessed) — true over
  # nothing by construction, and read only behind a reach that needs rows.
  # Named here so a sixth vacuous success is a red, never a silent pass.
  VACUOUS_SUCCESS = %w[task-grep-three-control workflow-fan-out-finders workflow-loop-until-dry
                       workflow-scout-then-fan].freeze

  def test_the_corpus_names_the_verified_tasks
    assert_equal 18, CORPUS.tasks.count(&:verification)
    assert_equal 30, CORPUS.tasks.size
    assert_empty VACUOUS_SUCCESS - CORPUS.names
    assert_empty BENCH.cost_stop_usd_by_task.keys - CORPUS.names, "a task-named cost stop must name a corpus task"
  end

  CORPUS.tasks.select(&:verification).each do |task|
    define_method(:"test_#{task.name.tr("-", "_")}_verification_answers_a_verdict_over_its_untouched_environment") do
      assert_the_verification_is_callable(task)
    end
  end

  CORPUS.tasks.each do |task|
    define_method(:"test_#{task.name.tr("-", "_")}_predicates_answer_on_an_empty_trace") do
      assert_the_predicates_answer_on_the_empty_trace(task)
    end
  end

  private

    def assert_the_verification_is_callable(task)
      Dir.mktmpdir("evals-verify-#{task.name}") do |home|
        seed = E2E::Evals::Seed.mint(home: home, project: File.join(home, "projects", task.name), model: "m")
        project = with_env(SMOKE_SIZES) { task.write_environment(File.join(home, "projects"), task.name, seed) }
        assert File.directory?(project.root), "#{task.name}: the environment has no directory"
        unwritten = task.restore.reject { |path| project.files.key?(path) }
        assert_empty unwritten, "#{task.name}: restore names a path the environment never writes"

        answer = task.verifier.call(project, seed)
        assert_kind_of Hash, answer, "#{task.name}: the verification answered #{answer.inspect}"
        assert_equal %w[output pass], answer.keys.sort, "#{task.name}: the verdict's keys"
        assert_includes [true, false], answer["pass"], "#{task.name}: pass must be a boolean"
        assert_kind_of String, answer["output"], "#{task.name}: output must be a String"
        refute answer["pass"], "#{task.name}: the untouched environment already passes — the check measures nothing"

        verdict = task.verify(project, seed)
        assert_equal false, verdict["pass"], "#{task.name}: Task#verify over the same project"
        assert_kind_of String, verdict["output"]
      end
    end

    def assert_the_predicates_answer_on_the_empty_trace(task)
      expected = task.expected
      reached = expected.reach.call(EMPTY)
      assert_kind_of String, reached, "#{task.name}: reach on an empty trace must name what is missing, got #{reached.inspect}"
      succeeded = expected.success.call(EMPTY)
      if VACUOUS_SUCCESS.include?(task.name)
        assert_equal true, succeeded, "#{task.name}: its success is an absence, true over nothing"
      else
        assert_kind_of String, succeeded, "#{task.name}: success on an empty trace must name what is missing, got #{succeeded.inspect}"
      end
      expected.conduct.each do |name, check|
        answer = check.call(EMPTY)
        assert answer == true || answer.is_a?(String), "#{task.name}: conduct #{name} answered #{answer.inspect}"
      end
      expected.facts.each_key { |name| assert_nothing_raised_for(task, name) { expected.facts.fetch(name).call(EMPTY) } }

      verdict = expected.verdict(EMPTY)
      refute verdict.reached, "#{task.name}: nothing is reached on an empty trace"
      assert_nil verdict.succeeded
      assert_equal reached, verdict.reason
    end

    def assert_nothing_raised_for(task, name)
      yield
    rescue StandardError => error
      flunk "#{task.name}: column #{name} raised #{error.class}: #{error.message[0, 200]}"
    end

    def with_env(pairs)
      saved = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      pairs.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
