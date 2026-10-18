require "test_helper"

# ONE RUN'S EVENTS, PUSHED. `rho watch` polls a snapshot, which is right
# for a table being redrawn and wrong for a page that wants a round's text
# as it arrives. The frames here are the same events the follower already
# receives, handed on as they land.
class LoopStreamTest < Minitest::Test
  # A RECORDING SINK, so every assertion is synchronous. Reading the real
  # body would mean `Writable#read`, which BLOCKS on an open body with
  # nothing queued — a test that asked for one frame too many would hang
  # the suite rather than fail it, which is exactly what happened while
  # this file was being written.
  class Sink
    attr_reader :written

    def initialize(raise_on: nil)
      @written = +""
      @raise_on = raise_on
      @closed = false
    end

    def write(chunk)
      raise @raise_on if @raise_on

      @written << chunk
    end

    def close_write = @closed = true
    def closed? = @closed
  end

  def sink = @sink ||= Sink.new
  def stream = @stream ||= Rho::FollowerStream.new(public_id: "al-1", sink: sink)

  def test_an_event_becomes_a_named_frame_a_browser_can_listen_for
    stream.deliver("task_status", "task_key" => "r1", "status" => "running")

    assert_equal %(event: task_status\ndata: {"task_key":"r1","status":"running"}\n\n), sink.written
  end

  def test_the_response_says_it_is_a_stream_and_must_not_be_buffered
    # Headers normalises multi-value fields to arrays, so read the wire
    # shape rather than whatever was handed in.
    headers = stream.response.headers.to_h.transform_values { |value| Array(value).join(", ") }

    assert_equal "text/event-stream", headers["content-type"]
    assert_includes headers["cache-control"], "no-transform"
    assert_equal "no", headers["x-accel-buffering"], "a buffering proxy defeats the point"
  end

  # SSE ignores a comment frame, which is exactly why it works as a probe:
  # a dead peer is discovered by a write failing rather than by nothing
  # ever happening on a run that is parked and silent.
  def test_a_heartbeat_is_a_comment_nobody_has_to_read
    assert stream.heartbeat
    assert_equal ": keep-alive\n\n", sink.written
  end

  def test_closing_says_why_once_and_refuses_to_write_again
    stream.close("turn_settled")

    assert_includes sink.written, %(event: closed\ndata: {"reason":"turn_settled"})
    assert_predicate sink, :closed?
    refute_predicate stream, :open?
    refute stream.deliver("task_status", {}), "a closed stream writes nothing"

    before = sink.written.dup
    stream.close("again")
    assert_equal before, sink.written, "closing twice says it once"
  end

  # A reader that went away must end the stream, not the daemon: a write
  # raising is the only signal a stream ever gets that nobody is there.
  def test_a_peer_that_went_away_closes_the_stream_rather_than_raising
    gone = Rho::FollowerStream.new(public_id: "al-1", sink: Sink.new(raise_on: IOError.new("peer gone")))

    refute gone.deliver("task_status", {}), "the write failed, so nothing was delivered"
    refute_predicate gone, :open?, "and the stream is over rather than retried forever"
    refute gone.heartbeat
  end

  # The real body is what ships. A sink redirects where frames are
  # WRITTEN and must never become what the response hands the peer.
  def test_the_response_always_carries_the_streaming_body
    assert_kind_of Protocol::HTTP::Body::Writable,
      Rho::FollowerStream.new(public_id: "al-1").response.body
    assert_kind_of Protocol::HTTP::Body::Writable, stream.response.body
  end
end
