require "test_helper"
require "support/live_journey"

# `rho do PROMPT --until COMMAND`: the daemon runs the acceptance command
# when the model ends its turn; exit 0 closes the loop with a summary,
# anything else hands the model the output and another attempt.
#
# THE CHECK IS STATEFUL ON PURPOSE: it fails the first time it runs and
# passes the second, so the journey proves the whole ladder — settle,
# check, the model reading a failure and continuing, check, pass,
# summary — without depending on the model to fail at anything. The
# model's task is trivial; the mechanism is what is under test.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveUntilTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-until-e2e")
  def teardown = finish_live_journey!

  def test_a_failing_check_hands_the_model_the_output_and_a_passing_one_closes_the_loop
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "check.sh"), <<~SH)
      #!/bin/sh
      # Fails on its first run, passes from the second: a ladder, not a coin.
      n=$(cat .check-count 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" > .check-count
      if [ ! -f note.txt ]; then echo "note.txt is missing"; exit 2; fi
      if [ "$n" -lt 2 ]; then echo "not yet: run $n"; exit 1; fi
      echo "ok on run $n"
    SH
    @daemon.control(:post, "/environment", body: { root: project })

    # The ladder counts the DAEMON's runs; a model that pre-runs the check
    # (the paragraph invites it to) would climb it alone. So this one
    # task says not to — the mechanism is under test, not the model's
    # diligence — and the count is asserted as at-least, not exactly.
    task = "Create a file named note.txt in this directory containing the single word hello. " \
           "Do not run check.sh yourself; just create the file and end your turn."
    output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project,
      "--until", "sh check.sh", "--attempts", "3")
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    assert_match(/^until:\s+sh check\.sh \(3 checks, in #{Regexp.escape(project)}\)/, output, output)
    loop_id = output[/^loop:\s+(\S+)/, 1]

    # Under the harness deadline on purpose: a stall must fail HERE, with
    # the logs dumped, not as a kill from outside with nothing to read.
    watched, = rho_watch(loop_id, "--timeout", "240")
    done = await_loop_completion(loop_id)
    report(done, watched)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE LADDER, IN THE TRACE: the kernel's first round (`r1`) with the gate hung below it, a
    # second attempt with its own gate, and the summary round that carries the answer.
    keys = done.fetch("tasks").to_h { |t| [t.fetch("key"), t] }
    %w[r1 check-1 work-2 check-2 summary].each do |key|
      assert keys.key?(key), "expected #{key} in the trace: #{keys.keys.inspect}"
    end
    assert_equal "completed", keys.fetch("check-1").fetch("status")
    assert_equal "completed", keys.fetch("check-2").fetch("status")
    assert_equal "completed", keys.fetch("summary").fetch("status")
    refute keys.key?("work-3"), "the second check passed; nothing more was planted"

    # THE PERSON SAW EACH VERDICT LAND, and the answer is the summary.
    assert_match(/^  check 1\/3: exit 1$/, watched, watched)
    assert_match(/^  check 2\/3: passed$/, watched, watched)
    result, = @daemon.cli("result", loop_id)
    assert_match(/note\.txt|hello/i, result, "the summary should say what was done: #{result}")
    assert_equal "hello", File.read(File.join(project, "note.txt"), encoding: Encoding::UTF_8).strip
    assert_operator Integer(File.read(File.join(project, ".check-count")).strip), :>=, 2,
      "the check ran at least twice"
  end

  private

    def report(row, watched)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live until ------------------------------------------------"
      puts "model:   #{MODEL}"
      puts "status:  #{row.fetch("status")}"
      puts "rounds:  #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:   #{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")}"
      puts "checks:  #{watched.scan(/check \d\/\d: [^\n]+/).join(" | ")}"
      puts "--------------------------------------------------------------"
    end
end
