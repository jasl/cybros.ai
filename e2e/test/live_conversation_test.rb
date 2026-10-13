require "test_helper"
require "support/live_journey"

# A CONVERSATION YOU KEEP TALKING TO. `rho do` opens one and its first turn does a real piece of
# work; `rho say` on the conversation is the second turn, and it is deliberately under-specified: it
# names no file. Only a turn whose history renders the first turn's rounds can know which file "that
# file" is — a turn that lost the context would have to ask, or guess wrong, and the assertion on
# disk would fail either way. Mid-way through turn 2 a steer goes in while a tool runs and lands in
# the continuation. And a note the first turn wrote through the kernel's memory tools is read back
# by the second.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveConversationTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  FIRST = "conversation-one-#{SecureRandom.hex(4)}".freeze
  SECOND = "conversation-two-#{SecureRandom.hex(4)}".freeze
  REMEMBERED = "remember-#{SecureRandom.hex(4)}".freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-conversation-e2e")
  def teardown = finish_live_journey!

  def test_a_conversation_keeps_its_context_and_the_next_thing_you_say_is_its_next_turn
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })
    note = File.join(project, "note.txt")

    # TURN 1: `live_agent_run`'s shape — a real file on disk — plus a
    # memory note written through the kernel's tools (item 7).
    output, status = @daemon.cli("do",
      "Create note.txt with the single line #{FIRST} and nothing else. " \
      "Then, using the memory tools, save a note at workspace/token.md whose whole content is " \
      "the word #{REMEMBERED}. Reply DONE when both are done.",
      "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation_id = output[/^conversation:\s+(\S+)/, 1]
    turn_id = output[/^turn:\s+(\S+)/, 1]
    loop_id = output[/^run:\s+(\S+)/, 1]
    refute_nil conversation_id, output
    refute_nil turn_id, output
    refute_nil loop_id, output

    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    assert_match(/^status:\s+completed$/, watched, watched)
    row = await_loop_completion(loop_id)
    assert_equal "completed", row.fetch("status"), summarize(row)
    assert_equal FIRST, File.read(note, encoding: Encoding::UTF_8).strip, "the first turn did the work"

    # TURN 2 NAMES NO FILE — and asks for the remembered word back. It
    # opens with one slow shell command on purpose: that is the window the
    # steer below goes in, so it lands in THIS turn's continuation rather
    # than queuing a third turn behind a turn that already finished.
    said, status = @daemon.cli("say", conversation_id,
      "First run the shell command `sleep 30` and wait for it to finish. " \
      "Then append the line #{SECOND} to that file, keeping the first line. " \
      "Then read the memory note you saved and append its word as a third line. Reply DONE.")
    assert_predicate status, :success?, said
    assert_match(/^queued:\s+\S+ \(pending\)$/, said, "idle, the next thing you say starts the next turn:\n#{said}")

    second = await_turn(conversation_id, after_loop: loop_id)
    loop_two = second.dig("payload", "run_public_id")
    refute_equal loop_id, loop_two, "the second turn is backed by a loop of its own"

    # A STEER MID-TURN 2, while a tool runs: it lands in the continuation.
    await_tool_running(loop_two)
    steered, status = @daemon.cli("say", loop_two, "Also append a fourth line reading STEERED.")
    assert_predicate status, :success?, steered
    assert_match(/queued:/, steered)

    done = await_loop_completion(loop_two)
    assert_equal "completed", done.fetch("status"), summarize(done)
    events = feed(conversation_id)
    completed = events.find do |item|
      item["type"] == "turn_status" && item.dig("payload", "status") == "completed" &&
        item.dig("payload", "run_public_id") == loop_two
    end
    refute_nil completed, "turn 2 never completed on the conversation feed"
    landed = events.find do |item|
      item["type"] == "input_materialized" && item.dig("payload", "run_public_id") == loop_two &&
        item.dig("payload", "task_key")
    end
    refute_nil landed, "the steer never landed on the conversation feed: #{events.map { |e| e["type"] }.inspect}"

    lines = File.read(note, encoding: Encoding::UTF_8).lines.map(&:strip).reject(&:empty?)
    assert_equal [FIRST, SECOND], lines.first(2),
      "the second turn carried the first turn's context: #{lines.inspect}"
    assert_includes lines, REMEMBERED, "the memory note written in turn 1 was read in turn 2: #{lines.inspect}"
    assert_includes lines, "STEERED", "the steer never reached the model: #{lines.inspect}"
    report(conversation_id, loop_id, loop_two, done)

    # NOTHING IS RUNNING, so a stop has nothing to cancel — and says so.
    stopped, status = @daemon.cli("stop", conversation_id)
    refute_predicate status, :success?, "stop on an idle conversation must refuse:\n#{stopped}"
    assert_match(/No reply is running/, stopped, "the kernel's `not_running` refusal, relayed as itself:\n#{stopped}")
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

    # A turn that settled before any tool ran is a failure HERE, legibly:
    # a steer sent after it would open a third turn and fail further down
    # as "the steer never landed", which says nothing about why.
    def await_tool_running(run_public_id, deadline: LOOP_DEADLINE_SECONDS)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        row = loop_row(run_public_id)
        return row if row.fetch("tasks").any? do |task|
          task["kind"] == "tool_task" && %w[dispatched running].include?(task["status"])
        end
        flunk "the turn settled before a tool ran, so there was no window for the steer: #{summarize(row)}" if
          CybrosAgent::Api::RUN_TERMINAL_STATUSES.include?(row.fetch("status"))
        raise "no tool ever ran: #{summarize(row)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 1
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

    def report(conversation_id, loop_one, loop_two, row)
      puts "\n--- live conversation -----------------------------------------"
      puts "model:         #{MODEL}"
      puts "conversation:  #{conversation_id}"
      puts "turn 1 loop:   #{loop_one}"
      puts "turn 2 loop:   #{loop_two}"
      puts "turn 2 tasks:  #{summarize(row)}"
      puts "--------------------------------------------------------------"
    end
end
