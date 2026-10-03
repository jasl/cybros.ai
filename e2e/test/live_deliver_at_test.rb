require "test_helper"
require "support/live_journey"
require "support/live_turns"
require "fileutils"
require "time"

# This paid journey posts `rho say CONVERSATION WORDS --in 15s` after a settled turn. The input is
# listed immediately but must not open its reply turn before `deliver_at`; the reply then completes.
# The SDK and member plane provide the timestamps, while deterministic scheduled-input journeys
# cover the wake, clear, cancel, and refusal paths.
#
# Paid, local, opt-in: E2E_LIVE=1. Two one-line turns: cents.
class LiveDeliverAtTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  DELAY = 15
  FIRST = "Reply with just the word hi.".freeze
  LATER = "Reply with just the word later.".freeze
  # The hold stops this many seconds before the time: two reads of one
  # machine's clock, with the kernel's own rounding between them.
  HOLD_MARGIN = 4
  HOLD_POLL = 2
  # The wake is the receipt's own path, kicked at the time; the minute
  # sweep is the backstop, so a turn owed at T is waited for past T + 60.
  WAKE_SECONDS = 120

  include E2E::LiveJourney
  include E2E::LiveTurns

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-deliver-at-e2e")
  def teardown = finish_live_journey!

  def test_a_timed_say_opens_its_turn_not_before_its_time_and_completes_after_it
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    conversation, _turn, loop_1 = rho_do_turn(FIRST, model: MODEL, dir: project)
    done_1 = await_loop_completion(loop_1)
    report_loop!(done_1)
    assert_equal "completed", done_1.fetch("status"), summarize(done_1)
    chat = conversation_door(conversation)
    before = chat.turns.list.items.map(&:position).max

    # THE POST: the row, its time, through the verb and the SDK.
    said_at = Time.now
    said, status = @daemon.cli("say", conversation, LATER, "--in", "#{DELAY}s")
    assert_predicate status, :success?, "rho say --in failed:\n#{said}"
    match = said.match(/^queued:\s+(\S+) \(pending, scheduled for (\S+)\)$/)
    refute_nil match, "a timed word is queued with its time:\n#{said}"
    input_id, printed_at = match.captures
    row = chat.inputs.list.items.find { |item| item.public_id == input_id }
    refute_nil row, "the row lists"
    assert_equal printed_at, row.deliver_at, "the verb printed the time the kernel holds"
    due_at = Time.iso8601(row.deliver_at)
    assert_in_delta said_at + DELAY, due_at, 3, "the delay is resolved against the kernel's clock"

    # THE PREDICATE: before its time the row is not in the room — no turn
    # opens, and the row stays listed.
    reads = 0
    while Time.now < due_at - HOLD_MARGIN
      assert_equal before, chat.turns.list.items.map(&:position).max, "a turn opened before the row's time"
      assert chat.inputs.list.items.any? { |item| item.public_id == input_id }, "the row left the listing before its time"
      reads += 1
      sleep HOLD_POLL
    end
    assert_operator reads, :>=, 1, "the hold never read the room"

    # THE WAKE: the turn opens not before the time, and completes.
    loop_2 = await_next_turn(conversation, after: [loop_1], deadline: (due_at - Time.now).ceil + WAKE_SECONDS)
    done_2 = await_loop_completion(loop_2)
    reply = await_reply(chat, after: before)
    assert_equal loop_2, reply.active_variant.agent_loop_public_id, "the reply's loop is the one the feed opened"
    turn_started = Time.iso8601(reply.created_at)
    loop_started = Time.iso8601(done_2["started_at"] || done_2.fetch("created_at"))
    answer, = @daemon.cli("result", loop_2)
    report(done_2, due_at, turn_started, loop_started, answer)
    started_after = turn_started >= due_at.floor && loop_started >= due_at.floor
    report_loop!(done_2, reached: true, succeeded: started_after && done_2.fetch("status") == "completed")

    assert_equal "completed", done_2.fetch("status"), summarize(done_2)
    assert_operator turn_started, :>=, due_at.floor, "the turn opened before the row's time"
    assert_operator loop_started, :>=, due_at.floor, "the loop started before the row's time"
    refute chat.inputs.list.items.any? { |item| item.public_id == input_id }, "materialized: the row is gone"
  end

  private

    def report(row, due_at, turn_started, loop_started, answer)
      puts "\n--- live deliver_at -------------------------------------------"
      puts "model:   #{MODEL}"
      puts "status:  #{row.fetch("status")}"
      puts "due:     #{due_at.utc.iso8601}"
      puts "turn:    #{turn_started.utc.iso8601} (#{(turn_started - due_at).round(1)} s after)"
      puts "loop:    #{loop_started.utc.iso8601} (#{(loop_started - due_at).round(1)} s after)"
      puts "answer:  #{answer.to_s.strip[0, 120].inspect}"
      puts "--------------------------------------------------------------"
    end
end
