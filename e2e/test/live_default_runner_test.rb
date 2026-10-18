require "test_helper"
require "support/live_journey"

# A future turn can explicitly select another environment after the host's
# default changes. Accepted calls retain their targets. Both Runner homes
# point at one fixture tree, and each target is proved by its own claim log.
# Paid, local, opt-in: E2E_LIVE=1.
class LiveDefaultRunnerTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-default-runner-e2e")
  def teardown = finish_live_journey!

  def test_an_explicit_next_turn_call_uses_the_selected_runner_environment
    connect_and_open_lane!
    runner_id = start_runner_rho!(home_prefix: "rho-live-default-runner-runner-e2e")
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
    loop_id = output[/^run:\s+(\S+)/, 1]
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

    # The host default changes future authoring. The next prompt explicitly
    # names the Runner whose qualified callable the model must choose.
    handed, status = @daemon.cli("set_default_runner", conversation_id, runner_id)
    assert_predicate status, :success?, "rho set_default_runner failed:\n#{handed}"
    assert_match(/#{Regexp.escape(conversation_id)}.*#{Regexp.escape(runner_id)}/, handed, handed)
    refute_match(/the tree is not synced/, handed, "both homes announce one root: no tree-sync warning\n#{handed}")
    refute_match(/^runner:/, handed, "the runner-mode rho is online: the slot is silent\n#{handed}")

    # TURN 2, on the runner-mode rho.
    said, status = @daemon.cli("say", conversation_id,
      "Use the bash callable for Runner #{runner_id}, whose root is #{project}. " \
      "Run the shell command `wc -c hello.txt` there and reply with just the number.")
    assert_predicate status, :success?, said
    assert_match(/^queued:\s+\S+ \(pending\)$/, said, said)
    refute_match(/^runner:/, said, "online: no slot line\n#{said}")

    second = await_turn(conversation_id, after_loop: loop_id)
    loop_two = second.dig("payload", "run_public_id")
    refute_equal loop_id, loop_two, "the second turn is backed by a loop of its own"
    done = await_loop_completion(loop_two)
    report(conversation_id, loop_id, loop_two, done, runner_id)
    assert_equal "completed", done.fetch("status"), summarize(done)

    # THE PROOF OF WHERE: turn 2's bash rows were addressed to the runner-mode rho and claimed by it
    # — its log says so; rho's own runner claimed nothing after the default change.
    bashes = done.fetch("tasks").select { |task| task["tool_name"] == "bash" }
    refute_empty bashes, "the model never ran a shell command: #{summarize(done)}"
    bashes.each do |task|
      assert_equal "completed", task.fetch("status"), task.inspect
      assert_equal runner_id, task.dig("target", "executor_public_id"), "accepted for another target: #{task.inspect}"
      assert_equal runner_id, task.dig("addressed_to", "executor_public_id"), "addressed elsewhere: #{task.inspect}"
      assert_equal({ "executor_public_id" => runner_id }, task.fetch("claimed_by"), task.inspect)
      assert_includes @runner.claimed_keys, task.fetch("key"),
        "the runner-mode rho's own log says it took the row: #{@runner.claims.inspect}"
      assert_equal "bash", @runner.claims.find { |claim| claim["task"] == task.fetch("key") }["tool"]
    end
    assert_equal own_claims_before, @daemon.claims.length,
      "rho's own runner claimed a row after the default change: #{@daemon.claims.last(3).inspect}"
    outputs = bashes.map { |task| task_output(loop_two, task.fetch("key")) }
    assert(outputs.any? { |text| text.match?(/\b[56]\b/) },
      "the row's output should carry the byte count: #{outputs.inspect}")
    refute_match TROUBLE, @runner.log_text, "the runner-mode rho met a refusal or a failure"
    refute_match TROUBLE, @daemon.log_text, "rho met a refusal or a failure"

    # Record how profile declaration changed when another environment became available.
    puts "declarations: #{declared_before} before the default change, #{declarations.length} after"
  end

  private

    # The next turn's `turn_status{running}` naming a loop other than the
    # one before it.
    def await_turn(conversation_id, after_loop:, deadline: LOOP_DEADLINE_SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = feed(conversation_id).find do |item|
          item["type"] == "turn_status" && item.dig("payload", "status") == "running" &&
            item.dig("payload", "run_public_id") &&
            item.dig("payload", "run_public_id") != after_loop
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
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
    end

    # Every `profile.declared` line rho wrote, oldest first.
    def declarations = @daemon.log_lines.select { |line| line["event"] == "profile.declared" }

    def report(conversation_id, loop_one, loop_two, row, runner_id)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live default selection ----------------------------------------------"
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
