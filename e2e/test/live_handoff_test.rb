require "test_helper"
require "support/live_journey"

# A HANDOFF MID-CONVERSATION, LIVE: a full-mode rho and a runner-mode rho on a second home, both the
# steward's, both pointed at ONE project directory — the deployment the design names, a rho and a
# standalone runner under one manager over the same tree. Turn 1 runs on rho's own runner. Then `rho
# handoff`, the recovery verb, moves the conversation's binding to the runner-mode rho: it replays
# nothing (M7) and warns of nothing, because the trees match. Turn 2's bash runs THERE — the proof
# is the second home's own log (`runner_task_claimed`), never `rho ps`; the first home claims
# nothing more after the handoff.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveHandoffTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-handoff-e2e")
  def teardown = finish_live_journey!

  def test_a_handoff_mid_conversation_moves_the_next_turns_bash_to_the_runner_mode_rho
    connect_and_open_lane!
    runner_id = start_runner_rho!(home_prefix: "rho-live-handoff-runner-e2e")
    own_runner = @daemon.status.dig("identity", "runner_executor_public_id")
    refute_nil own_runner, "a full-mode rho registers a runner row"

    # ONE TREE, BOTH HOMES: the same checkout, announced by each.
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })
    @runner.control(:post, "/environment", body: { root: project })

    # TURN 1, on rho's own runner.
    output, status = @daemon.cli("do",
      "Create a file hello.txt in the current directory containing the single word hello. " \
      "Then run the shell command `cat hello.txt` and reply DONE.",
      "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    loop_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil conversation_id, output
    refute_nil loop_id, output

    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    first = await_loop_completion(loop_id)
    assert_equal "completed", first.fetch("status"), summarize(first)
    assert_equal "hello", File.read(File.join(project, "hello.txt"), encoding: Encoding::UTF_8).strip,
      "the first turn did the work"
    assert(@daemon.claims.any? { |claim| claim["tool"] == "bash" },
      "turn 1's bash ran on rho's own runner: #{@daemon.claims.inspect}")
    own_claims_before = @daemon.claims.length
    declared_before = declarations.length

    # THE VERB: the conversation's binding moves; nothing is replayed; the
    # trees match so no warning; the target is online so no slot line.
    handed, status = @daemon.cli("handoff", conversation_id, runner_id)
    assert_predicate status, :success?, "rho handoff failed:\n#{handed}"
    assert_equal "handed off: #{conversation_id} → #{runner_id} (was #{own_runner})", handed.lines.first.chomp, handed
    refute_match(/the tree is not synced/, handed, "both homes announce one root: no tree-sync warning\n#{handed}")
    refute_match(/^runner:/, handed, "the runner-mode rho is online: the slot is silent\n#{handed}")

    # TURN 2, on the runner-mode rho.
    said, status = @daemon.cli("say", conversation_id,
      "Now run the shell command `wc -c hello.txt` and reply with just the number.")
    assert_predicate status, :success?, said
    assert_match(/^queued:\s+\S+ \(pending\)$/, said, said)
    refute_match(/^runner:/, said, "online: no slot line\n#{said}")

    second = await_turn(conversation_id, after_loop: loop_id)
    loop_two = second.dig("payload", "agent_loop_public_id")
    refute_equal loop_id, loop_two, "the second turn is backed by a loop of its own"
    done = await_loop_completion(loop_two)
    report(conversation_id, loop_id, loop_two, done, runner_id)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE PROOF OF WHERE: turn 2's bash rows were addressed to the runner-mode rho and claimed by it
    # — its log says so; rho's own runner claimed nothing after the handoff.
    bashes = done.fetch("tasks").select { |task| task["tool_name"] == "bash" }
    refute_empty bashes, "the model never ran a shell command: #{summarize(done)}"
    bashes.each do |task|
      assert_equal "completed", task.fetch("status"), task.inspect
      assert_equal runner_id, task.dig("addressed_to", "executor_public_id"), "addressed elsewhere: #{task.inspect}"
      assert_equal({ "executor_public_id" => runner_id }, task.fetch("claimed_by"), task.inspect)
      assert_includes @runner.claimed_keys, task.fetch("key"),
        "the runner-mode rho's own log says it took the row: #{@runner.claims.inspect}"
      assert_equal "bash", @runner.claims.find { |claim| claim["task"] == task.fetch("key") }["tool"]
    end
    assert_equal own_claims_before, @daemon.claims.length,
      "rho's own runner claimed a row after the handoff: #{@daemon.claims.last(3).inspect}"
    outputs = bashes.map { |task| task_output(loop_two, task.fetch("key")) }
    assert(outputs.any? { |text| text.match?(/\b[56]\b/) },
      "the row's output should carry the byte count: #{outputs.inspect}")
    refute_match TROUBLE, @runner.log_text, "the runner-mode rho met a refusal or a failure"
    refute_match TROUBLE, @daemon.log_text, "rho met a refusal or a failure"

    # RECORDED, NOT REQUIRED: the runner-mode rho serves the same gem tree,
    # so the union's bytes did not move and no re-declaration was needed.
    puts "declarations: #{declared_before} before the handoff, #{declarations.length} after"
  end

  private

    # The next turn's `turn_status{running}` naming a loop other than the
    # one before it.
    def await_turn(conversation_id, after_loop:, deadline: LOOP_DEADLINE_SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation_id).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
            item.dig("payload", "agent_loop_public_id") &&
            item.dig("payload", "agent_loop_public_id") != after_loop
        end
        return found if found
        raise "the next turn never started" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    def feed(conversation_id)
      items = []
      after = nil
      loop do
        page = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation_id}/events" \
          "?limit=200#{after ? "&after=#{after}" : ""}")
        rows = Array(page["events"])
        items.concat(rows)
        after = page.dig("pagination", "next_after")
        break if after.nil? || rows.empty?
      end
      items
    end

    def task_output(loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
    end

    # Every `profile.declared` line rho wrote, oldest first.
    def declarations = @daemon.log_lines.select { |line| line["event"] == "profile.declared" }

    def report(conversation_id, loop_one, loop_two, row, runner_id)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live handoff ----------------------------------------------"
      puts "model:        #{MODEL}"
      puts "conversation: #{conversation_id}"
      puts "turn 1 loop:  #{loop_one} (rho's own runner)"
      puts "turn 2 loop:  #{loop_two} (runner-mode rho #{runner_id})"
      puts "status:       #{row.fetch("status")}"
      puts "rounds:       #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "calls:        #{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")}"
      puts "runner log:   #{@runner.claims.map { |c| "#{c["task"]}:#{c["tool"]}" }.join(" ")}"
      puts "--------------------------------------------------------------"
    end
end
