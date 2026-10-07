require "support/runtime"

class TelegramFollowerRefreshTest < Minitest::Test
  include TelegramRuntimeSupport

  class ReadingBridge < TelegramRuntimeSupport::Bridge
    attr_reader :reads
    attr_accessor :run_rows, :page_size, :snapshot_failure, :event_rows

    def initialize
      super
      @reads, @event_rows = [], []
      @current = { "sequence" => 1, "status" => "completed", "complete" => true }
    end

    def runs = @run_rows || super

    def turns(id, **options)
      @reads << [:turns, id]
      rows = super
      @page_size ? rows.first(@page_size) : rows
    end

    def snapshot(id, **options)
      @reads << [:inputs, id]
      if @snapshot_failure
        error, @snapshot_failure = @snapshot_failure, nil
        raise error
      end
      super
    end

    def pending(id, **options)
      @reads << [:questions, id]
      super
    end

    def events(id, after: nil, **_options)
      @reads << [:events, id, after]
      index = @event_rows.index { |row| row.fetch("cursor") == after }
      { "events" => index ? @event_rows.drop(index + 1) : @event_rows,
        "pagination" => { "next_after" => nil, "watermark" => @event_rows.last&.fetch("sequence") || 0 } }
    end
  end

  def setup
    super
    @bridge = ReadingBridge.new
    @runtime = runtime
  end

  def test_thirteen_idle_histories_do_not_repeat_turn_and_input_reads_every_five_seconds
    13.times { |index| @runtime.consume(telegram_message(index + 1, "/new")) }
    @runtime.tick
    11.times { tick_after(5) }

    assert_equal 13, reads(:turns)
    assert_equal 13, reads(:inputs)
    assert_equal 13 * 12, reads(:questions), "child attention remains a separate reconciliation"

    tick_after(5)
    assert_equal 26, reads(:turns), "a quiet follower still gets a bounded durable check"
    assert_equal 26, reads(:inputs)
  end

  def test_absent_local_followers_use_the_same_bounded_refresh_and_restart_reads_immediately
    @runtime.consume(telegram_message(1, "start"))
    @bridge.run_rows = {}
    @runtime.tick
    11.times { tick_after(5) }
    assert_equal 1, reads(:turns)
    assert_equal 1, reads(:inputs)

    tick_after(5)
    assert_equal 2, reads(:turns)
    @runtime = runtime
    @runtime.tick
    assert_equal 3, reads(:turns), "the refresh hint is not persisted across restart"
  end

  def test_a_new_event_refreshes_an_old_conversation_and_delivers_its_background_answer
    @runtime.consume(telegram_message(1, "start"))
    @runtime.consume(telegram_message(2, "/new"))
    @runtime.tick
    @bridge.turn_rows["conversation-1"] = [turn(0, "Late background answer")]
    @bridge.run_rows = {
      "conversation-1" => @bridge.current.merge("sequence" => 2),
      "conversation-2" => @bridge.current,
    }
    tick_after(5)

    assert_equal 3, reads(:turns), "only the changed host needs another durable read"
    assert_equal 0, tracker.fetch("position")
    tick_after(1)
    assert @client.calls.any? { |_method, params| params[:text] == "Late background answer" }
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  def test_history_keeps_paging_without_another_event_until_the_position_stops_advancing
    @runtime.consume(telegram_message(1, "start"))
    @bridge.page_size = 2
    @bridge.turn_rows["conversation-1"] = 5.times.map { |position| turn(position, "inherited").merge("inherited" => true) }
    @runtime.tick
    3.times { tick_after(5) }

    assert_equal 4, tracker.fetch("position")
    assert_equal 4, reads(:turns), "three partial history pages and one empty tail establish the end"
    tick_after(5)
    assert_equal 4, reads(:turns)
    refute @client.calls.any? { |_method, params| params[:text] == "inherited" }
  end

  def test_a_failed_input_refresh_retries_with_the_same_event_sequence
    @runtime.consume(telegram_message(1, "start"))
    @bridge.snapshot_failure = Rho::ConnectionError.new("temporary input read failure")
    @runtime.define_singleton_method(:sleep) { |_seconds| }
    @runtime.tick
    tick_after(5)

    assert_equal 2, reads(:turns)
    assert_equal 2, reads(:inputs)
    tick_after(5)
    assert_equal 2, reads(:turns), "only the successful full refresh may suppress the next read"
  end

  def test_child_questions_refresh_while_the_parent_event_sequence_stays_unchanged
    @runtime.consume(telegram_message(1, "start"))
    @runtime.tick
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "ask", "kind" => "ask", "question" => "Which child option?" }]
    tick_after(5)

    assert_equal 1, reads(:turns)
    assert_equal 1, reads(:inputs)
    assert_equal 2, reads(:questions)
    assert @client.calls.any? { |_method, params| params[:text].to_s.include?("Which child option?") }
    @bridge.pending_rows = []
    tick_after(5)
    assert_empty @state.read.fetch("questions")
  end

  def test_recovered_projection_changes_and_lost_followers_are_not_unchanged_history
    @runtime.consume(telegram_message(1, "start"))
    @runtime.tick
    @bridge.current = @bridge.current.merge("turn" => "recovered-turn", "status" => "running", "complete" => false)
    tick_after(5)
    assert_equal 2, reads(:turns), "expired event recovery can move the projection without changing its sequence"

    @bridge.run_rows = {}
    tick_after(5)
    assert_equal 3, reads(:turns), "losing the follower needs a durable read and reattach opportunity"
    tick_after(5)
    assert_equal 3, reads(:turns)
  end

  def test_new_voice_input_mapping_is_refreshed_without_waiting_for_a_follower_wake
    @runtime.consume(telegram_message(1, "start"))
    @runtime.tick
    event_reads_before_voice = reads(:events)
    @state.change do |document|
      document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")["voice_inputs"] = ["voice-input"]
    end
    @bridge.event_rows = [{ "type" => "input_materialized", "cursor" => "voice-event", "sequence" => 1, "payload" => {
      "input_public_id" => "voice-input", "turn_public_id" => "turn-0",
    } }]
    @bridge.turn_rows["conversation-1"] = [turn(0, "Spoken request answer")]
    tick_after(5)

    assert_equal event_reads_before_voice + 1, reads(:events), "request and voice mappings share one event read per refresh"
    assert_equal 2, reads(:turns)
    assert_empty tracker.fetch("voice_inputs")
    assert_equal 0, tracker.fetch("position")
  end

  private

    def tick_after(seconds)
      @now += seconds
      @runtime.tick
    end

    def reads(kind) = @bridge.reads.count { |read| read.first == kind }

    def tracker = @state.read.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")
end
