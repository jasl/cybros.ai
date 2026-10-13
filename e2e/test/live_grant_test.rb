require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"

# Under `--approval ask`, a real model's call parks. `rho approve LOOP KEY --always` releases it and
# adds the exact command to the declared allow rules. A later matching call must run with `origin:
# rule` and no new park; `rho rules` identifies the conversation that granted it.
#
# The task names the goal — one command, run as written — never the
# tool; which tool the model reached for is read off the park and
# recorded. A second turn whose call differs from the granted one parks
# again (the grant is exact): the lane stops that turn, prints both calls
# and is red on the flow — the model's, recorded, never tuned around.
#
# Paid, local, opt-in: E2E_LIVE=1. Two one-command turns: cents.
class LiveGrantTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  COMMAND = "printf granted > granted.txt".freeze
  TASK = "Run this shell command exactly as written, then reply DONE: #{COMMAND}".freeze
  # Further parks inside a turn (a model that also lists the file) are
  # approved plainly, bounded: past this the model has looped.
  MAX_PARKS = 4

  include E2E::LiveJourney
  include E2E::LiveTurns

  # THE PROJECT IS OUTSIDE THE HOME (the mock grant test's `outside`,
  # `approval_test.rb`): the runner floor vetoes a command naming
  # `$RHO_HOME` and an absolute `write` under it, so a model that spells
  # the directory out is judged by the grant alone, never the floor.
  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-grant-e2e")
    @project = Dir.mktmpdir("rho-live-grant-project")
  end

  def teardown
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_approve_always_on_the_first_park_lets_the_same_call_run_unparked_on_the_next_ask_turn
    connect_and_open_lane!
    project = @project
    @daemon.control(:post, "/environment", body: { root: project })

    # ---- TURN 1: the park, the grant -----------------------------------
    # THE PARK: the loop stays `running` while the held call rests at
    # `needs_approval` (`LiveJourney#parked?` — the mock lane's read); a
    # settled row here is a model that never asked.
    conversation_1, _turn, loop_1 = rho_do_turn(TASK, "--approval", "ask", model: MODEL, dir: project)
    parked = await_loop_rest(loop_1)
    flunk "the model never asked for a call under ask: #{summarize(parked)}" unless parked?(parked)
    key = parked_keys(parked).first
    granted_call = call_of(loop_1, key)
    approved, status = @daemon.cli("approve", loop_1, key, "--always")
    assert_predicate status, :success?, "rho approve --always failed:\n#{approved}"
    assert_match(/^approved:\s+#{Regexp.escape(key)}$/, approved, approved)
    grant_line = approved[/^granted:.*$/]
    refute_nil grant_line, "the grant was never printed:\n#{approved}"
    # A re-park (the effect profile moved under the park) is decided once
    # more, as a person would after reading `rho task` again.
    if approved.match?(/^status:\s+needs_approval/)
      approved, status = @daemon.cli("approve", loop_1, key)
      assert_predicate status, :success?, approved
    end
    done_1 = approve_further_parks!(loop_1, except: [key])
    first_row = done_1.fetch("tasks").find { |task| task.fetch("key") == key }
    report("turn 1 (the grant)", done_1, granted_call, grant_line)
    report_loop!(done_1, reached: true, succeeded: done_1.fetch("status") == "completed")
    assert_equal "completed", done_1.fetch("status"), summarize(done_1)
    assert_equal "agent", first_row.dig("approval", "origin"), "the parked call itself: the approver's grant #{first_row.inspect}"
    FileUtils.rm_f(File.join(project, "granted.txt"))

    # ---- TURN 2: the same call, no park ----------------------------------
    conversation_2, _turn, loop_2 = rho_do_turn(TASK, "--approval", "ask", model: MODEL, dir: project)
    done_2 = await_loop_rest(loop_2)
    if parked?(done_2)
      second_key = parked_keys(done_2).first
      second_call = call_of(loop_2, second_key)
      stop_conversation!(conversation_2)
      done_2 = await_loop_completion(loop_2)
      report("turn 2 (parked again)", done_2, second_call, nil)
      report_loop!(done_2, reached: second_call == granted_call, succeeded: false)
      flunk "the second turn parked: the grant is exact and the call differed — granted #{granted_call.inspect}, " \
            "asked #{second_call.inspect}"
    end
    same = done_2.fetch("tasks").select { |task| task["kind"] == "tool_task" }
      .find { |task| call_of(loop_2, task.fetch("key")) == granted_call }
    report("turn 2 (released by the grant)", done_2, same && granted_call, nil)
    report_loop!(done_2, reached: !same.nil?, succeeded: !same.nil? && same.dig("approval", "origin") == "rule")
    assert_equal "completed", done_2.fetch("status"), summarize(done_2)
    refute_nil same, "the second turn never made the granted call #{granted_call.inspect}: #{summarize(done_2)}"
    assert_equal "completed", same.fetch("status"), same.inspect
    assert_equal "rule", same.dig("approval", "origin"), "the profile's list allowed it: #{same.inspect}"
    assert_equal 0, feed(conversation_2).count { |item| item["type"] == "attention_required" }, "never parked"
    if granted_call.first == "bash"
      assert_equal "granted", File.read(File.join(project, "granted.txt"), encoding: Encoding::UTF_8).strip,
        "the released call never ran"
    end

    # ---- `rho rules`: the grant, on the loop and key it was made on ------
    listed, status = @daemon.cli("rules")
    assert_predicate status, :success?, "rho rules failed:\n#{listed}"
    assert_match(/^session grants \(until the daemon's next boot\):$/, listed, listed)
    assert_match(/^  1  #{Regexp.escape(granted_call.first)}\b.*granted \S+ on #{Regexp.escape(loop_1)} #{Regexp.escape(key)} \(conversation #{Regexp.escape(conversation_1)}\)$/,
      listed, "the grant names the conversation it was made on:\n#{listed}")
  end

  private

    # The call a park holds, as the grant keys it: the tool and its text
    # key (`command` for bash, `path` for write/edit) — or the tool alone.
    def call_of(run_public_id, key)
      detail = task_detail(run_public_id, key)
      input = Hash.try_convert(detail["tool_input"]) || {}
      [detail["tool_name"], input["command"] || input["path"]].compact
    end

    # Any further park in the same turn is approved plainly (no grant),
    # bounded by MAX_PARKS; answers the settled row. `rho approve` returns
    # with the row released (the verb runs under the loop lock), so a key
    # read parked again is a RE-PARK (the effect profile moved under the
    # park), decided once more as a person would — never a spin.
    def approve_further_parks!(run_public_id, except:)
      decided = except.dup
      loop do
        row = await_loop_rest(run_public_id)
        return row unless parked?(row)

        parked_keys(row).each do |key|
          decided << key
          flunk "the model looped: #{decided.size} parks in one turn" if decided.size > MAX_PARKS
          printed = approve!(run_public_id, key)
          printed = approve!(run_public_id, key) if printed.match?(/^status:\s+needs_approval/)
          assert_match(/^status:\s+(dispatched|running)$/, printed, printed)
          puts "park:   #{key} #{call_of(run_public_id, key).inspect} → approve"
        end
      end
    end

    def approve!(run_public_id, key)
      printed, status = @daemon.cli("approve", run_public_id, key)
      assert_predicate status, :success?, "rho approve failed:\n#{printed}"
      printed
    end

    def report(label, row, call, grant_line)
      tools = row.fetch("tasks").select { |task| task.fetch("kind") == "tool_task" }
      puts "\n--- live grant: #{label} --------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "calls:  #{tools.map { |task| task["tool_name"] }.tally.map { |name, n| "#{name}x#{n}" }.join(" ")}"
      puts "call:   #{call.inspect}"
      puts "grant:  #{grant_line}" if grant_line
      puts "tasks:  #{summarize(row)}"
      puts "--------------------------------------------------------------"
    end
end
