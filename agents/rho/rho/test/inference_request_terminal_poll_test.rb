require "test_helper"

# An open subscription cannot detect a missing final wake: there is no next
# sequence to expose the gap. Drive the real SDK feed with cooperative fibers
# so the resource can finish while the socket stays open, without wall time.
class InferenceRequestTerminalPollTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :public_id, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)
  InferenceRequest = Data.define(:result) do
    def output_text = result&.output_text
  end

  class Socket
    attr_reader :closed

    def initialize
      @events = []
      @closed = false
    end

    def push(event) = @events << event

    def each
      until @closed
        event = @events.shift
        event ? yield(event) : Fiber.yield
      end
    end

    def unsubscribe = @closed = true
  end

  class Realtime
    def rebind = true
    def close = nil
  end

  class Lane
    attr_accessor :resource, :fetch_override
    attr_reader :socket, :fetches

    def initialize
      @resource = InferenceRequest.new(result: nil)
      @socket = Socket.new
      @fetches = []
    end

    def fetch(public_id)
      @fetches << public_id
      @fetch_override ? @fetch_override.call : @resource
    end

    def realtime_opener(_public_id, _realtime, items: nil) = -> { @socket }

    def feed(public_id, realtime: nil, items: nil)
      CybrosAgent::KernelFeed.new(
        replay: ->(_cursor) { Page.new(items: [], next_after: nil, watermark: 0) },
        subscribe: realtime_opener(public_id, realtime, items: items)
      )
    end
  end

  def setup
    @lane = Lane.new
    @fibers = []
    @sleeps = []
    @run = Rho::InferenceRequestRun.new(
      inference_requests: @lane, public_id: "os-1", realtime: Realtime.new,
      sleeper: ->(seconds) { @sleeps << seconds; Fiber.yield }
    )
  end

  def teardown
    @run.stop
    tick
  end

  def test_a_silent_open_socket_does_not_hide_the_authoritative_terminal_result
    start
    tick
    refute @run.snapshot.complete
    assert_nil @run.snapshot.result
    refute @lane.socket.closed

    @lane.resource = terminal(output_text: "authoritative answer")
    2.times { tick }

    snapshot = @run.snapshot
    assert snapshot.complete, "the last wake may be lost without disconnecting the socket"
    assert_equal "completed", snapshot.status
    assert_equal "authoritative answer", snapshot.text
    assert_equal @lane.resource.result.to_h, snapshot.result
    assert_equal 0, snapshot.sequence, "REST completion does not invent an event cursor"
    assert @lane.socket.closed
    refute @fibers.any?(&:alive?), "both followers finish when the resource does"
    assert @sleeps.all? { |seconds| seconds == Rho::InferenceRequestRun::POLL_SECONDS }
  end

  def test_a_cancellation_without_a_terminal_wake_finishes_both_followers
    @lane.resource = terminal(status: "canceled")
    start
    2.times { tick }

    snapshot = @run.snapshot
    assert snapshot.complete
    assert_equal "canceled", snapshot.status
    assert_equal "", snapshot.text
    assert_equal @lane.resource.result.to_h, snapshot.result
    assert @lane.socket.closed
    refute @fibers.any?(&:alive?)
    assert_empty @sleeps
  end

  def test_transient_rest_errors_back_off_and_a_pending_result_keeps_waiting
    responses = [
      -> { raise CybrosAgent::Api::RateLimited.new(retry_after: 7) },
      -> { raise CybrosAgent::Api::ServerError.new("briefly unavailable") },
      -> { InferenceRequest.new(result: nil) },
      -> { terminal(output_text: "done") },
    ]
    @lane.fetch_override = -> { responses.shift.call }
    start
    3.times { tick }
    refute @run.snapshot.complete
    assert_nil @run.snapshot.result

    2.times { tick }

    assert @run.snapshot.complete
    assert_equal "done", @run.snapshot.text
    assert_equal [7, Rho::InferenceRequestRun::POLL_SECONDS, Rho::InferenceRequestRun::POLL_SECONDS], @sleeps
    assert_equal Array.new(4, "os-1"), @lane.fetches
    refute @fibers.any?(&:alive?)
  end

  def test_stopping_during_a_rest_fetch_does_not_adopt_the_late_result
    @lane.fetch_override = -> { Fiber.yield; terminal(output_text: "late") }
    start
    tick
    @run.stop
    tick

    refute @run.snapshot.complete
    assert_nil @run.snapshot.result
    assert_equal "", @run.snapshot.text
    assert_equal ["os-1"], @lane.fetches
    assert @lane.socket.closed
    refute @fibers.any?(&:alive?)
    assert_empty @sleeps
  end

  def test_a_terminal_event_wins_over_an_older_in_flight_rest_read
    pending = @lane.resource
    @lane.fetch_override = lambda do
      if @lane.fetches.length == 1
        Fiber.yield
        pending
      else
        @lane.resource
      end
    end
    start
    tick

    @lane.resource = terminal(output_text: "final")
    @lane.socket.push(event(1, "result", {}))
    tick

    assert @run.snapshot.complete
    assert_equal "final", @run.snapshot.text
    assert_equal @lane.resource.result.to_h, @run.snapshot.result
    assert_equal 1, @run.snapshot.sequence
    assert_equal %w[os-1 os-1], @lane.fetches
    refute @fibers.any?(&:alive?)
  end

  def test_a_late_terminal_fetch_does_not_replace_an_already_adopted_result
    @lane.resource = terminal(output_text: "final")
    @lane.fetch_override = lambda do
      Fiber.yield if @lane.fetches.length == 1
      @lane.resource
    end
    @lane.socket.push(event(1, "result", {}))
    start
    tick
    first_result = @run.snapshot.result
    assert @run.snapshot.complete

    # The event's earlier GET returns after the REST follower completed. Any
    # buffered preview behind that wake must not replace the final projection.
    @lane.socket.push(event(2, "text_delta", { "text" => "late preview" }))
    @lane.socket.push(event(3, "rollback", {}))
    @lane.socket.push(event(4, "run_status", { "status" => "running" }))
    tick

    assert_same first_result, @run.snapshot.result
    assert_equal "final", @run.snapshot.text
    assert_equal "completed", @run.snapshot.status
    assert_equal %w[os-1 os-1], @lane.fetches
    refute @fibers.any?(&:alive?)
  end

  def test_a_stopped_run_starts_neither_resource_reads_nor_subscriptions
    @run.stop
    start
    tick

    assert_empty @lane.fetches
    refute @run.snapshot.complete
    refute @fibers.any?(&:alive?)
    assert_empty @sleeps
  end

  def test_a_terminal_wake_without_its_authoritative_result_is_still_malformed
    @lane.socket.push(event(1, "result", {}))
    start

    error = assert_raises(CybrosAgent::Api::MalformedResponse) { tick }

    assert_includes error.message, "preceded its authoritative result"
    refute @run.snapshot.complete
    assert_nil @run.snapshot.result
    assert @lane.socket.closed
    tick
    refute @fibers.any?(&:alive?)
    assert_equal ["os-1"], @lane.fetches
  end

  private

    def start
      @run.start(->(&block) { @fibers << Fiber.new(&block) })
    end

    def tick
      @fibers.each { |fiber| fiber.resume if fiber.alive? }
    end

    def event(sequence, type, payload)
      Event.new(sequence: sequence, cursor: "c#{sequence}", public_id: "e#{sequence}",
                type: type, payload: payload)
    end

    def terminal(status: "completed", output_text: nil)
      InferenceRequest.new(result: CybrosAgent::Api::InferenceRequestResult.new(
        status: status, finish_quality: nil, output_text: output_text,
        usage: nil, timing: nil, error: nil, reasoning: nil, output_files: nil
      ))
    end
end
