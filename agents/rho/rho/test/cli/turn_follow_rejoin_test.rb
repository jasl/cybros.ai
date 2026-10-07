require "test_helper"

class TurnFollowRejoinTest < Minitest::Test
  class Core < Rho::Core
    attr_accessor :status, :stay_behind, :caught_up_on_close, :expire_events
    attr_reader :deadlines

    def initialize
      @status = "running"
      @stay_behind = false
      @caught_up_on_close = false
      @event_reads = 0
      @deadlines = []
    end

    def follower_events(_id, deadline: nil)
      @deadlines << deadline
      if @deadlines.length == 1 || @stay_behind
        yield "snapshot", follower_row(nil)
      else
        yield "snapshot", { "turn" => "mine", "run_public_id" => "my-run", "status" => "running",
          "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["call"] } }
        yield "text_delta", { "text" => "my answer" }
        yield "turn_status", { "turn_public_id" => "mine", "run_public_id" => "my-run",
          "status" => "completed", "run_status" => "completed" }
      end
      @caught_up = true if @caught_up_on_close
      yield "closed", { "reason" => "turn_settled" }
    end

    def follower_row(_id)
      return { "turn" => "mine", "run_public_id" => "my-run", "status" => "running" } if @caught_up

      { "turn" => "earlier", "run_public_id" => "earlier-run", "status" => "completed",
        "complete" => true, "text" => "old answer" }
    end

    def host_events(_id, after: nil)
      @event_reads += 1
      if @expire_events && @event_reads > 1
        return CybrosAgent::Api::ConversationEventPage.new(items: [], next_after: nil, watermark: 1)
      end

      event = CybrosAgent::Api::ConversationEvent.new(sequence: 1, cursor: "c1", public_id: "ev1",
        resource_type: "conversation", resource_public_id: "conversation", occurred_at: "2026-09-22T00:00:00Z",
        type: "turn_status", payload: { "turn_public_id" => "mine", "run_public_id" => "my-run",
          "status" => @status, "run_status" => @status })
      CybrosAgent::Api::ConversationEventPage.new(items: after ? [] : [event], next_after: nil, watermark: 1)
    end

    def variants(_id, _turn) = []
  end

  def setup
    @core = Core.new
    @frames = []
    @parks = []
    @sleeps = []
    @now = [0]
  end

  def test_an_earlier_settled_snapshot_rejoins_until_the_receipts_turn_can_be_followed
    follow = machine

    assert_equal :completed, follow.follow
    assert_equal 2, @core.deadlines.length
    assert_equal [0.25], @sleeps
    assert_equal [["my-run", ["call"]]], @parks
    assert_equal ["my answer"], @frames.filter_map { |type, payload| payload["text"] if type == "text_delta" }
    refute @frames.any? { |_, payload| payload["turn"] == "earlier" }
  end

  def test_the_follower_catching_up_after_the_old_stream_closed_still_rejoins
    @core.caught_up_on_close = true
    follow = machine

    assert_equal :completed, follow.follow
    assert_equal 2, @core.deadlines.length
    assert_equal [0.25], @sleeps
    assert_equal [["my-run", ["call"]]], @parks
  end

  def test_the_original_deadline_bounds_rejoins_without_a_busy_run
    @core.stay_behind = true
    follow = machine(deadline: 0.6)

    assert_equal :timeout, follow.follow
    assert_equal 3, @core.deadlines.length
    [0.6, 0.35, 0.1].zip(@core.deadlines).each { |expected, actual| assert_in_delta expected, actual, 0.0001 }
    assert_equal 3, @sleeps.length
    assert_in_delta 0.6, @sleeps.sum, 0.0001
  end

  def test_cancel_during_the_catch_up_wait_still_returns_the_targets_terminal_word
    @core.stay_behind = true
    follow = machine { @core.status = "canceled" }

    assert_equal :canceled, follow.follow
    assert_equal [0.25], @sleeps
    assert_equal 2, @core.deadlines.length
    assert_empty @parks
  end

  def test_expired_target_events_cannot_reuse_an_earlier_running_status_to_keep_rejoining
    @core.stay_behind = true
    @core.expire_events = true
    follow = machine(deadline: 0.6)

    assert_equal :refused, follow.follow
    assert_equal Rho::Cli::TurnFollow::STREAM_ENDED, follow.reason
    assert_equal 1, @core.deadlines.length
    assert_empty @sleeps
  end

  private

    def machine(deadline: nil, &on_wait)
      follow = Rho::Cli::TurnFollow.new(core: @core, conversation: "conversation", turn: "mine", run_public_id: "my-run",
        deadline: deadline, on_frame: ->(type, payload) { @frames << [type, payload] },
        on_park: ->(run_id, keys) { @parks << [run_id, keys] })
      now, sleeps = @now, @sleeps
      clock = -> { now.first }
      sleeper = lambda do |duration|
        sleeps << duration
        now[0] += duration
        on_wait&.call
      end
      follow.define_singleton_method(:monotonic, &clock)
      follow.define_singleton_method(:sleep, &sleeper)
      follow
    end
end
