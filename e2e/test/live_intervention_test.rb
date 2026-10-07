require "test_helper"
require "support/live_journey"
require "json"

# GETTING IN A CONVERSATION'S WAY, from the command line, with a real model: saying something to the
# reply in flight, pausing and resuming it, and stopping one that would otherwise never finish.
# Every verb addresses the CONVERSATION `rho do` opened: `say` and `stop` are the core's host-typed
# verbs — a conversation's stop is its cancellation — and `pause`, `resume` and `answer` are Ops
# verbs that resolve the loop backing the current turn through the daemon's row. The loop id `rho
# do` prints is kept only for the kernel's own reads (`GET /runs/{id}`), the way
# `live_conversation` keeps it.
#
# SAY is proven through the ask: the reply parks on a question, the
# person steers it BEFORE answering, and the model's next round — which
# sees the answer and the steer together — does the extra thing the
# steer asked for. That is deterministic where "steer it mid-tool-call"
# would be a race against the model's own cadence.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveInterventionTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-intervene-e2e")
  def teardown = finish_live_journey!

  def test_say_pause_resume_and_stop_from_the_command_line
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    # ---- SAY, through the ask ------------------------------------------
    ask_task = <<~TEXT.strip
      Write a file called first.txt containing exactly the word FIRST. Then
      ask me — by calling the `ask` tool and nothing else:

        ask({prompt: "Shall I continue?"})

      Your next round will receive my answer as an <answer> block, and
      possibly further instructions from me; follow them. Reply DONE when
      finished.
    TEXT
    conversation_a, loop_a = open_conversation(ask_task, project)

    asking = await_ask(conversation_a)
    task_key = asking.fetch("attention").fetch("blocked_task_keys").first
    assert_path_exists File.join(project, "first.txt"), "the first step was not done before asking"

    # The steer goes in while the reply is parked: the turn is running, so
    # the word binds to it and lands with the answer.
    said, status = @daemon.cli("say", conversation_a,
      "Also write a file called second.txt containing exactly SECOND before you finish.")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    assert_match(/^queued:\s+\S+ \(steering\)$/, said, "a steer binds to the reply in flight:\n#{said}")

    answered, status = @daemon.cli("answer", conversation_a, task_key, "Yes, continue.")
    assert_predicate status, :success?, "rho answer failed:\n#{answered}"
    # An agent-created loop's ask is rho's own inbox row: the answer commits on the executor plane,
    # and the verb says which door it took.
    assert_match(/^answered:\s+#{Regexp.escape(task_key)} \(executor plane\)$/, answered,
      "a conversation id resolves the loop backing its turn:\n#{answered}")

    done = await_loop_completion(loop_a)
    report("say", done)
    assert_equal "completed", done.fetch("status"), summarize(done)
    second = File.join(project, "second.txt")
    assert_path_exists second, "the steer never reached the model"
    assert_equal "SECOND", File.read(second, encoding: Encoding::UTF_8).strip
    refute_nil turn_status(feed(conversation_a), status: "completed", loop: loop_a),
      "the turn never completed on the conversation feed"

    # ---- PAUSE / RESUME -----------------------------------------------
    pause_task = "Write a file called third.txt containing exactly THIRD, then reply DONE."
    conversation_b, loop_b = open_conversation(pause_task, project)

    paused, status = @daemon.cli("pause", conversation_b, "--force")
    assert_predicate status, :success?, "rho pause failed:\n#{paused}"
    assert_match(/status:\s+paused/, paused)
    sleep 2
    assert_equal "paused", loop_row(loop_b).fetch("status"), "the loop did not stay paused"

    resumed, status = @daemon.cli("resume", conversation_b)
    assert_predicate status, :success?, "rho resume failed:\n#{resumed}"
    done = await_loop_completion(loop_b)
    report("pause/resume", done)
    assert_equal "completed", done.fetch("status"), summarize(done)
    assert_path_exists File.join(project, "third.txt")

    # ---- STOP --------------------------------------------------------
    endless = <<~TEXT.strip
      Count upward from 1 forever. For each number N, write a file called
      count-N.txt containing N, one file per tool call, and never stop on
      your own. Do not reply DONE.
    TEXT
    conversation_c, loop_c = open_conversation(endless, project)
    sleep 8
    stopped, status = @daemon.cli("stop", conversation_c)
    assert_predicate status, :success?, "rho stop failed:\n#{stopped}"
    assert_match(/^stopped:\s+#{Regexp.escape(conversation_c)} \(conversation\)$/, stopped,
      "a conversation's stop is its cancellation:\n#{stopped}")

    final = await_loop_completion(loop_c)
    report("stop", final)
    assert_equal "canceled", final.fetch("status"), "stop did not cancel the reply: #{summarize(final)}"
    files_at_stop = Dir[File.join(project, "count-*.txt")].size
    sleep 6
    assert_equal files_at_stop, Dir[File.join(project, "count-*.txt")].size,
      "the reply kept writing after it was stopped"
    canceled = await_turn_status(conversation_c, status: "canceled", loop: loop_c)
    refute_nil canceled, "the canceled turn never settled on the conversation feed"
  end

  private

    # `rho do` opens a conversation and prints the ids the lane reads:
    # the conversation every verb addresses, the loop the kernel reads.
    def open_conversation(task, project)
      output, status = @daemon.cli("do", task, "--model", MODEL, "--dir", project)
      assert_predicate status, :success?, "rho do failed:\n#{output}"
      conversation = output[/^conversation:\s+(\S+)/, 1]
      run_public_id = output[/^run:\s+(\S+)/, 1]
      refute_nil conversation, output
      refute_nil run_public_id, output
      [conversation, run_public_id]
    end

    # The daemon's rows are keyed by the HOST — the conversation `rho do` opened — and carry the
    # loop backing its current turn.
    def followed(conversation)
      @daemon.control(:get, "/followers").fetch("followers").find do |row|
        row.fetch("public_id") == conversation
      end
    end

    def await_ask(conversation)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      loop do
        row = followed(conversation)
        return row if row && row["attention"]
        flunk "the reply finished without asking: #{row.fetch("status")}" if row && row["complete"]
        flunk "the model never asked: #{row.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 2
      end
    end

    def await_turn_status(conversation, status:, loop:, deadline: 60)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        found = turn_status(feed(conversation), status: status, loop: loop)
        return found if found
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 2
      end
    end

    def turn_status(items, status:, loop:)
      items.find do |item|
        item["type"] == "turn_status" && item.dig("payload", "status") == status &&
          item.dig("payload", "run_public_id") == loop
      end
    end

    # The conversation's whole feed, paged through the replay window.
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

    def report(label, row)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live intervention: #{label} ------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "calls:  #{tools.size} (#{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")})"
      puts "--------------------------------------------------------------"
    end
end
