require "test_helper"

# THE WATCHER'S CHANNEL FOR A PROCESS: the completed lines of
# every row the table holds, posted under the row's HOST as one
# `process_output` frame per row per tick, the exit on the last; a
# refusal ends a row's posting once, a transport blip drops a tick's
# lines, a printer faster than the buffer loses its oldest, and a daemon
# with no runner slot posts nothing at all. Driven by `tick`, never the clock.
class ProcessesPumpTest < Minitest::Test
  CONVERSATION = { "conversation_public_id" => "c-1" }.freeze
  RUN = { "run_public_id" => "al-1" }.freeze

  class Kept
    attr_reader :warned, :told

    def initialize
      @warned = []
      @told = []
    end

    def warn(event, **fields) = @warned << [event, fields]
    def info(event, **fields) = @told << [event, fields]
  end

  def pump(interval_ms: 250, log: nil, &post)
    @posted = []
    Rho::Processes::Pump.new(interval_ms: interval_ms, log: log, sleeper: ->(_seconds) { nil },
      post: post || ->(frame) { @posted << frame; true })
  end

  def test_lines_are_batched_per_row_under_its_host_and_the_exit_closes_the_row
    subject = pump
    subject.line("p1", CONVERSATION, "up")
    subject.line("p1", CONVERSATION, "listening on :4000")
    subject.line("p2", RUN, "svc ready")
    subject.line("p3", nil, "a person's process is nobody's frame")

    assert_equal 2, subject.tick
    assert_equal [
      { "conversation_public_id" => "c-1", "process_id" => "p1", "lines" => ["up", "listening on :4000"] },
      { "run_public_id" => "al-1", "process_id" => "p2", "lines" => ["svc ready"] },
    ], @posted
    assert_equal 0, subject.tick, "nothing new, nothing posted"

    subject.line("p1", CONVERSATION, "bye")
    subject.exited("p1", CONVERSATION, 3)
    subject.exited("p2", RUN, nil)
    assert_equal 2, subject.tick
    assert_equal({ "conversation_public_id" => "c-1", "process_id" => "p1", "lines" => ["bye"], "exit" => 3 },
      @posted[2])
    assert_equal({ "run_public_id" => "al-1", "process_id" => "p2", "lines" => [], "exit" => nil },
      @posted[3], "a signal death carries a null exit on an otherwise empty last frame")
    subject.line("p1", CONVERSATION, "late")
    assert_equal 1, subject.tick, "a forgotten row starts over if it prints again"
  end

  def test_the_cadence_floor_is_the_runners_mirror_and_the_interval_must_be_positive
    assert_equal Rho::Runner::Progress::MIN_INTERVAL_MS, pump.interval_ms
    assert_raises(ArgumentError) { Rho::Processes::Pump.new(post: ->(_) { true }, interval_ms: 0) }
  end

  # `not_bound`: this runner is not the host's binding — the row's posting
  # ends, said once; a transport blip drops this tick's lines and the next
  # tick carries on.
  def test_a_refusal_ends_a_rows_posting_once_and_a_transport_blip_drops_one_tick
    log = Kept.new
    answers = [
      -> { raise CybrosAgent::Api::Conflict.new("no", code: "stale_claim") },
      -> { raise CybrosAgent::TransportError, "connection reset" },
      -> { true },
    ]
    subject = pump(log: log) { |frame| @posted << frame; answers.shift.call }
    subject.line("p1", CONVERSATION, "a")
    subject.line("p2", RUN, "b")
    assert_equal 0, subject.tick
    assert_equal [["processes.progress_refused", { id: "p1", code: "stale_claim" }]], log.warned
    assert_equal 1, log.told.count { |event, _| event == "processes.progress_dropped" }

    subject.line("p1", CONVERSATION, "never")
    subject.line("p2", RUN, "c")
    assert_equal 1, subject.tick
    assert_equal ["b", "c"], @posted.select { |frame| frame["process_id"] == "p2" }.flat_map { |frame| frame["lines"] }
    refute @posted.any? { |frame| frame["lines"].include?("never") }, "a denied row posts no more"
  end

  def test_collected_source_stops_only_its_posting_and_never_prints_the_claim_token
    log = Kept.new
    source = { "run_public_id" => "source-run", "task_key" => "start", "claim_token" => "private-claim" }
    host = CONVERSATION.merge("source" => source)
    subject = pump(log: log) { |frame| @posted << frame; raise CybrosAgent::Api::NotFound.new("gone", code: "not_found") }
    subject.line("p1", host, "ready")
    subject.tick
    subject.line("p1", host, "later")
    subject.tick
    assert_equal 1, @posted.length
    assert_equal source, @posted.first.fetch("source")
    refute_includes log.warned.inspect, "private-claim"
  end

  def test_a_daemon_with_no_runner_slot_posts_nothing_and_says_nothing
    log = Kept.new
    subject = pump(log: log) { |_frame| false }
    subject.line("p1", CONVERSATION, "a")
    assert_equal 0, subject.tick
    assert_empty log.warned
    assert_empty log.told
  end

  def test_a_printer_faster_than_the_cadence_loses_its_oldest_lines_and_the_frame_says_so
    subject = pump
    (Rho::Processes::Pump::BUFFER_LINES + 3).times { |index| subject.line("p1", RUN, "line #{index}") }
    subject.tick

    frame = @posted.fetch(0)
    assert_equal Rho::Processes::Pump::BUFFER_LINES + 1, frame["lines"].length
    assert_equal "[… 3 earlier lines dropped: the process outran the frame cadence …]", frame["lines"].first
    assert_equal "line 3", frame["lines"][1]
    assert_equal "line #{Rho::Processes::Pump::BUFFER_LINES + 2}", frame["lines"].last
  end

  def test_a_frame_stays_under_the_envelope_by_keeping_the_newest_lines
    subject = pump
    20.times { |index| subject.line("p1", RUN, "#{index}:#{"x" * 4000}") }
    subject.tick

    lines = @posted.fetch(0)["lines"]
    assert_operator lines.sum { |line| line.bytesize + 1 }, :<=, Rho::Processes::Pump::FRAME_LINE_BYTES
    assert lines.last.start_with?("19:"), "the newest line is kept"
    refute lines.first.start_with?("0:"), "the oldest is what the bound drops"
  end

  def test_run_ticks_until_the_pump_is_closed
    ticks = 0
    subject = Rho::Processes::Pump.new(post: ->(_) { true }, sleeper: ->(_) { nil })
    subject.define_singleton_method(:tick) do
      ticks += 1
      close if ticks == 3
      0
    end
    subject.run
    assert_equal 3, ticks
    assert_predicate subject, :closed?
  end
end
