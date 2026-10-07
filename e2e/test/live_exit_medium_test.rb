require "test_helper"
require "support/live_journey"
require "support/fixture_project"
require "support/evals/bench"
require "support/evals/corpus"
require "support/evals/report_line"

# GATE 3, THE MEDIUM TASK (roadmap "Gate 3 — the round's exit"): a
# multi-file FEATURE with tests, in a project the model has never seen —
# grep, read, plan, edit several files, run the suite, iterate on failures.
# The Small task is `live_debugging` (one defect, one file); this one has
# no defect at all: the code is correct and incomplete.
#
# THE FEATURE'S TESTS SHIP, RED. A feature "with tests" the model writes
# is gameable (a test that asserts what the code already does) and cannot
# be scored on a weak model; so `test/currency_test.rb` is in the fixture
# beside the green suite, and it is the specification: an entry's
# currency, a journal's refusal to mix currencies without a rates table,
# per-currency totals on the report, a column on the CSV export. Each of
# those exercises a different source file, so the feature touches at
# least three files by construction — no single edit can pass it.
#
# WHAT IS MEASURED. The suite's own exit status after the loop (never the
# loop's status or what the model said); every shipped test file
# byte-identical afterwards (a model that edits the specification has a
# green suite that proves nothing); at least one test the model added of
# its own; and the transcript showing the kernel drove every round — no
# round failed, nothing waited on a person, no attention item on the
# feed, because this lane scripts no human step.
#
# Paid, local, opt-in: E2E_LIVE=1, on E2E_LIVE_MODEL (both weak models
# under the sweep). Budget: ten to twenty-five rounds.
class LiveExitMediumTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  SUITE = "ruby -Ilib -Itest test/all.rb".freeze

  TASK = <<~TEXT.strip.freeze
    This directory is a small Ruby ledger library. FEATURE.md describes a
    feature that is not implemented yet: currencies. Its tests are already
    in test/currency_test.rb and they fail.

    Run the suite with `ruby -Ilib -Itest test/all.rb`, then read
    FEATURE.md and the code under lib/, and implement the feature so the
    WHOLE suite passes. The shipped tests are the specification — do not
    change any file under test/. Add at least one test of your own, in a
    new file under test/, for something you changed. Run the suite once
    more to confirm it is green, then reply DONE.
  TEXT

  # THE SHIPPED TESTS: three green files, one red. The CSV test on the
  # green side pins rows and quoting and not the header line, so the
  # feature can widen the header without contradicting a shipped test.
  SHIPPED_TESTS = %w[test/money_test.rb test/journal_test.rb test/report_test.rb test/currency_test.rb test/all.rb].freeze

  # THE PROJECT IS THE CORPUS'S: `e2e/evals/tasks/exit-medium/environment/` — the ledger library,
  # FEATURE.md, the three green test files and the red currency_test.rb.
  PROJECT = E2E::Evals::Corpus.load_task(File.join(E2E::Evals::Corpus::DIR, "exit-medium"),
    canary: E2E::Evals::Bench.read.canary).static_files

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-exit-medium-e2e", task: "exit-medium")

  def teardown = finish_live_journey!

  def test_a_real_model_implements_a_multi_file_feature_against_shipped_tests
    connect_and_open_lane!

    project = E2E::FixtureProject.write(@home, "ledger", PROJECT)
    # THE SUITE FAILS BEFORE, or the task is not the task.
    refute project.passes?(SUITE), "the fixture project was already green"

    @daemon.control(:post, "/environment", body: { root: project.root })
    output, status = @daemon.cli("do", TASK, "--model", MODEL, "--dir", project.root)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil loop_id, "rho do printed no loop id:\n#{output}"

    # Under the journey deadline on purpose: a stall fails HERE with the
    # logs dumped, not as a kill from outside with nothing to read.
    rho_watch(loop_id, "--timeout", "900")
    done = await_loop_completion(loop_id, deadline: 1500)
    items = feed(conversation_id)
    report(done, project, items)

    # (1) THE SUITE IS THE VERDICT.
    assert project.passes?(SUITE),
      "the suite is still red after the loop reported #{done.fetch("status")}:\n#{project.run(SUITE).first}"
    # (2) AND IT IMPLEMENTED THE SPECIFICATION, not rewrote it.
    assert_empty project.changed(SHIPPED_TESTS), "it changed the tests instead of the code"
    # (3) AND ADDED ONE OF ITS OWN.
    assert_operator project.added_tests, :>=, 1, "the model added no test of its own"
    # (4) THE KERNEL DROVE EVERY ROUND: no round failed, nothing is still
    # waited on, nobody was asked, and the feed never called for a person.
    assert_equal "completed", done.fetch("status"), summarize(done)
    tasks = done.fetch("tasks")
    failed_rounds = tasks.select { |t| t.fetch("kind") == "model_task" && t.fetch("status") != "completed" }
    assert_empty failed_rounds.map { |t| describe_task(t) }, "a round did not complete: #{summarize(done)}"
    assert_empty tasks.select { |t| t["waiting_on"] }.map { |t| describe_task(t) }, "a task still waits: #{summarize(done)}"
    assert_nil done["attention"], "the loop rests holding for a person: #{done["attention"].inspect}"
    assert_empty items.select { |item| item["type"] == "attention_required" }.map { |item| item["payload"] },
      "the feed called for a person, and this lane scripts none"
    # (5) THE SHAPE OF THE WORK: it looked, it edited, it ran.
    used = tasks.select { |t| t.fetch("kind") == "tool_task" }.map { |t| t["tool_name"] }.uniq
    assert_predicate used & %w[read grep find ls], :any?, "it never explored the project: #{used.inspect}"
    assert_predicate used & %w[write edit], :any?, "it never edited a file: #{used.inspect}"
    assert_includes used, "bash", "it never ran the suite: #{used.inspect}"
  end

  private

    # The CONVERSATION's feed: a loop backing a turn has no feed of its
    # own, and its items ride its conversation's.
    def feed(conversation)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    # WHAT IT DID, printed whatever the verdict.
    def report(row, project, items = [])
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live exit: medium ------------------------------------------"
      puts "model:   #{MODEL}"
      puts "status:  #{row.fetch("status")}"
      puts "rounds:  #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:   #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "suite:   #{project.passes?(SUITE) ? "green" : "RED"}"
      puts "tests:   #{project.added_tests} added; changed shipped: #{project.changed(SHIPPED_TESTS).inspect}"
      # the one report line every paid lane prints (`LiveJourney#report_loop!`: the spend and the
      # sealed request's bytes through the evals reader).
      report_loop!(row, events: items.select { |item| item["type"] == "context_compacted" },
        reached: !tools.empty?, succeeded: row.fetch("status") == "completed",
        task_pass: project.passes?(SUITE) && project.changed(SHIPPED_TESTS).empty?)
      puts "--- journal.rb after -------------------------------------------"
      puts File.read(File.join(project.root, "lib/ledger/journal.rb"), encoding: Encoding::UTF_8)
      puts "----------------------------------------------------------------"
    end
end
