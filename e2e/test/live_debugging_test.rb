require "test_helper"
require "support/live_journey"
require "support/evals/bench"
require "support/evals/corpus"
require "shellwords"

# CAN IT DEBUG? — the evaluation the fizzbuzz journey cannot be.
#
# Writing a file from a specification exercises the loop; it does not
# exercise the thing a coding agent is actually for. This gives a model a
# project it has never seen, a test suite that fails, and no statement of
# what is wrong. To finish it must explore (the bug is not in the file the
# failure names), read, form a hypothesis, edit, and re-run — and the
# verdict is the suite's own exit status, not a transcript.
#
# THE BUG IS DELIBERATELY NOT WHERE IT LOOKS. The failing assertion is in
# `cart_test.rb` about a total; the defect is an off-by-one in a
# DIFFERENT file's discount tier. A model that patches the arithmetic at
# the assertion makes one test pass and another fail, so "run the whole
# suite" is what distinguishes understanding from pattern-matching.
#
# Paid, local, opt-in: E2E_LIVE=1, and the account needs the key of the model's
# provider (`DEEPSEEK_API_KEY` for the default floor; `E2E::ProviderLanes::KEY_NAMES`).
class LiveDebuggingTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  TASK = <<~TEXT.strip.freeze
    This project's test suite is failing. Run it with `ruby -Ilib -Itest
    test/cart_test.rb`, work out why, and fix it.

    Do not change the tests — they describe what the code is supposed to
    do. Fix the source in lib/ so the whole suite passes, then run it once
    more to confirm. Reply DONE when every test passes.
  TEXT

  # THE PROJECT IS THE CORPUS'S: `e2e/evals/tasks/exit-small/environment/` — a small project with
  # one real bug. `discount_rate` is off by one at the tier boundary: at exactly 10 items a customer
  # should get 10%, and this gives them 5%. Two tests fail from that one defect, in two different
  # files, and neither failure message names the guilty line.
  PROJECT = E2E::Evals::Corpus.load_task(File.join(E2E::Evals::Corpus::DIR, "exit-small"),
    canary: E2E::Evals::Bench.read.canary).static_files

  include E2E::LiveJourney

  # `exit-small` is the Small's exit name (Gate 3; `rake live_exit_small`),
  # the report line's task and the cost stop's key.
  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-debug-e2e", task: "exit-small")

  def teardown = finish_live_journey!

  def test_a_real_model_finds_and_fixes_a_bug_it_was_not_shown
    connect_and_open_lane!

    project = write_project
    # THE SUITE FAILS BEFORE, or the task is not the task.
    refute suite_passes?(project), "the fixture project was already green"

    @daemon.control(:post, "/environment", body: { root: project })
    output, status = @daemon.cli("do", TASK, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    run_public_id = output[/^run:\s+(\S+)/, 1]

    completed = await_loop_completion(run_public_id)
    report(completed, project)
    # the one report line every paid lane prints (`LiveJourney#report_loop!`, through the evals
    # scorer's reader: spend, the sealed request's bytes).
    report_loop!(completed, reached: completed.fetch("tasks").any? { |t| t["kind"] == "tool_task" },
      succeeded: completed.fetch("status") == "completed", task_pass: suite_passes?(project))

    # THE SUITE IS THE VERDICT. Not the loop's status and not what it
    # said: a model that reports DONE over a red suite has failed the
    # task, and that is the failure a transcript assertion cannot see.
    assert suite_passes?(project),
      "the suite is still red after the loop reported #{completed.fetch("status")}:\n" \
      "#{run_suite(project).first}"

    # AND IT FIXED THE CAUSE, not the symptom. The tests are the
    # specification, so a model that edited them to agree with the bug
    # has produced a green suite that proves nothing.
    assert_equal PROJECT.fetch("test/cart_test.rb"),
      File.read(File.join(project, "test/cart_test.rb")),
      "it changed the tests instead of the code"
  end

  private

    def write_project
      root = File.join(@home, "shop")
      PROJECT.each do |path, contents|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      root
    end

    def run_suite(project)
      output = `cd #{Shellwords.escape(project)} && ruby -Ilib -Itest test/cart_test.rb 2>&1`
      [output, $?]
    end

    def suite_passes?(project) = run_suite(project).last.success?

    # WHAT IT DID, printed whatever the verdict — an evaluation that only
    # says pass/fail teaches nothing about the harness.
    def report(row, project)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live debugging -------------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "suite:  #{suite_passes?(project) ? "green" : "RED"}"
      puts "--- pricing.rb after -----------------------------------------"
      puts File.read(File.join(project, "lib/pricing.rb"))
      puts "--------------------------------------------------------------"
    end
end
