require "test_helper"
require "rho/env/webrtc_stream"

class WebrtcStreamTest < Minitest::Test
  Stream = Rho::Env::WebrtcStream

  class Gate < Rho::Env::ClaimRealtime
    attr_accessor :permitted, :closed
    def initialize
      @permitted = true
      @closed = false
    end
    def allowed? = @permitted && !@closed
    def closed? = @closed
    def close
      @closed = true
      nil
    end
  end

  class Connection < Rho::Env::WebrtcConnection
    attr_accessor :connection_id, :writable, :ready
    attr_reader :sent, :incoming
    def initialize
      @connection_id = "first"
      @sent = []
      @incoming = []
      @writable = true
      @ready = true
    end
    def poll
      data = @incoming.shift(@incoming.size)
      Rho::Env::WebrtcTransport::Poll.new(data: data, state: @ready ? "connected" : "retrying", ready: @ready, pair: nil)
    end
    def send_bytes(bytes)
      @sent << bytes if @writable
      @writable
    end
    def close
      @ready = false
      nil
    end
  end

  def setup
    @now = 0.0
    @gate = Gate.new
    @context = Rho::Env::ExecutionContext.new(realtime: @gate)
    @connection = Connection.new
    @stream = Stream.new(connection: @connection, context: @context, window_bytes: 16, window_seconds: 30.0, clock: -> { @now })
    @receiver = Stream::Receiver.new
  end

  def teardown
    @stream.close
  end

  def test_sustained_output_without_a_reader_keeps_only_the_bounded_tail
    @stream = Stream.new(connection: @connection, context: @context, clock: -> { @now })
    512.times do
      @stream.write_output("x" * (16 * 1024))
      @stream.poll
    end
    assert_empty @connection.sent
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [0, 8 * 1024 * 1024 - 8 * 1024], [gap.from, gap.to]
    request
    assert_equal 8 * 1024, @receiver.receive(@connection.sent.shift).first.bytes.bytesize
    assert_equal 8 * 1024 * 1024, @receiver.offset
    request
    assert_empty @connection.sent
  end

  def test_overrun_recovers_live_output_while_the_producer_keeps_writing
    @stream = Stream.new(connection: @connection, context: @context, window_bytes: 16 * 1024, clock: -> { @now })
    32.times { @stream.write_output("a" * 1024) }
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [0, 31 * 1024], [gap.from, gap.to]
    @stream.write_output("b" * 1024)
    request
    output = @receiver.receive(@connection.sent.shift).first
    assert_equal "a" * 1024, output.bytes
    request
    assert_equal "b" * 1024, @receiver.receive(@connection.sent.shift).first.bytes
  end

  def test_retained_output_survives_replacement_and_unknown_delivery_is_deduplicated
    @stream.write_output("one\x00\xff".b)
    @stream.poll
    assert_empty @connection.sent
    request
    first = @connection.sent.shift
    assert_equal "one\x00\xff".b, @receiver.receive(first).first.bytes
    @stream.write_output("two")
    @connection.connection_id = "replacement"
    @stream.poll
    assert_empty @connection.sent
    request
    second = @connection.sent.shift
    assert_equal "two", @receiver.receive(second).first.bytes
    assert_empty @receiver.receive(first)
    assert_empty @receiver.receive(second)
    assert_equal 8, @receiver.offset
  end

  def test_capacity_and_time_expiry_have_explicit_gap_events
    @stream.write_output("a" * 10)
    @stream.write_output("b" * 10)
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [0, 10], [gap.from, gap.to]
    assert_equal "Output gap: 10 bytes are unavailable.", gap.message
    request
    assert_equal "b" * 10, @receiver.receive(@connection.sent.shift).first.bytes
    @stream.write_output("expired")
    @now = 30.0
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [20, 27], [gap.from, gap.to]
    request
    assert_empty @connection.sent
  end

  def test_permission_loss_omits_content_and_explicit_close_clears_capture
    @stream.write_output("before")
    @gate.permitted = false
    @stream.write_output("private")
    request
    assert_empty @connection.sent
    @gate.permitted = true
    @stream.poll
    assert_equal "before", @receiver.receive(@connection.sent.shift).first.bytes
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [6, 13], [gap.from, gap.to]
    @stream.write_output("after")
    @gate.closed = true
    @stream.poll
    assert_empty @connection.sent
    @gate.closed = false
    request
    gap = @receiver.receive(@connection.sent.shift).first
    assert_equal [13, 18], [gap.from, gap.to]
  end

  def test_input_remains_single_use_and_cursor_requests_bound_slow_consumer_output
    @stream.write_output("a" * 8)
    @stream.write_output("b" * 8)
    request
    10.times { @stream.poll }
    assert_equal 1, @connection.sent.size
    @receiver.receive(@connection.sent.shift)
    @connection.incoming << @receiver.input('{"type":"resume","offset":0}')
    assert_equal ['{"type":"resume","offset":0}'], @stream.poll.data
    assert_empty @stream.poll.data
    assert_equal "received", @receiver.receive(@connection.sent.shift).first.status
    @stream.acknowledge_input(0)
    assert_equal "written", @receiver.receive(@connection.sent.shift).first.status
    request
    assert_equal "b" * 8, @receiver.receive(@connection.sent.shift).first.bytes
    @context.cancel
    count = @connection.sent.size
    assert_raises(Rho::Env::ExecutionContext::Cancelled) { @stream.poll }
    assert_raises(Rho::Env::ExecutionContext::Cancelled) { @stream.write_output("late") }
    assert_equal count, @connection.sent.size
  end

  def test_failed_send_preserves_output_until_another_peer_resumes
    @stream.write_output("pending")
    @connection.writable = false
    request
    assert_empty @connection.sent
    @connection.connection_id = "next"
    @connection.writable = true
    @stream.poll
    assert_empty @connection.sent
    request
    assert_equal "pending", @receiver.receive(@connection.sent.shift).first.bytes
  end

  def test_window_bounds_tiny_blocks_and_expires_even_without_a_reader
    window = Stream::Window.new(max_bytes: 1024, max_age: 30.0, clock: -> { @now })
    300.times { window.append("x", retain: true) }
    assert_equal 256, window.retained_bytes
    gap = window.next_frame(0)
    assert_equal [0, 299], [gap.from, gap.to]
    @now = 30.0
    window.expire
    assert_equal 0, window.retained_bytes
    assert_equal 300, window.next_frame(44).to
  end

  def test_receiver_trims_overlap_and_rejects_silent_holes_or_wrong_direction
    output = ->(offset, bytes) { Stream::Protocol.encode(Stream::Output.new(offset: offset, bytes: bytes)) }
    assert_equal "abcd", @receiver.receive(output.call(0, "abcd")).first.bytes
    assert_equal "ef", @receiver.receive(output.call(2, "cdef")).first.bytes
    assert_raises(Rho::Env::Error) { @receiver.receive(output.call(7, "h")) }
    assert_raises(Rho::Env::Error) { @receiver.receive(@receiver.input("input")) }
    @connection.incoming << @receiver.resume
    assert_raises(Rho::Env::Error) { @stream.poll }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode('{"type":"resume","offset":1.5}') }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode("{") }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode("[]") }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode('{"type":"gap","from":4,"to":2}') }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode("x" * (16 * 1024 + 1)) }
  end

  def test_unobserved_successful_send_can_be_requested_again_after_reconnect
    @stream.write_output("unobserved")
    request
    lost = @connection.sent.shift
    @connection.connection_id = "replacement"
    @stream.poll
    request
    replay = @connection.sent.shift
    assert_equal lost, replay
    assert_equal "unobserved", @receiver.receive(replay).first.bytes
    assert_empty @receiver.receive(lost)
  end

  def test_large_binary_output_is_framed_and_partial_resume_preserves_byte_offsets
    window = Stream::Window.new(max_bytes: 16 * 1024, max_age: 30.0, clock: -> { @now })
    bytes = (0..255).to_a.pack("C*") * 64
    window.append(bytes, retain: true)
    first = window.next_frame(3)
    assert_equal bytes.byteslice(3, 8192 - 3), first.bytes
    second = window.next_frame(8192)
    assert_equal bytes.byteslice(8192, 8192), second.bytes
    assert_operator Stream::Protocol.encode(second).bytesize, :<=, Rho::Env::WebrtcTransport::MAX_BYTES
    assert_nil window.next_frame(16 * 1024)
    assert_raises(ArgumentError) { window.append(bytes + "x", retain: true) }
    window.clear
    assert_equal 0, window.retained_bytes
    assert_equal 16 * 1024, window.next_frame(0).to
  end

  def test_input_requires_resume_and_closed_stream_cannot_retain_or_send_more
    @connection.incoming << @receiver.input("before-resume")
    assert_raises(Rho::Env::Error) { @stream.poll }
    @stream.close
    assert_raises(Rho::Env::Error) { @stream.write_output("late") }
    assert_raises(Rho::Env::Error) { @stream.poll }
    assert_empty @connection.sent
  end

  def test_input_receipts_distinguish_acceptance_from_partial_pty_write
    request
    @connection.incoming << @receiver.input("hello")
    assert_equal ["hello"], @stream.poll.data
    receipt = @receiver.receive(@connection.sent.shift).first
    assert_equal [1, 1, "received", 5], [receipt.id, receipt.sequence, receipt.status, receipt.bytes]
    assert_empty @connection.sent
    @stream.acknowledge_input(3)
    receipt = @receiver.receive(@connection.sent.shift).first
    assert_equal [1, 1, "written", 3], [receipt.id, receipt.sequence, receipt.status, receipt.bytes]
    assert_empty @stream.poll.data
  end

  def test_lost_receipt_is_not_replayed_and_sequence_survives_peer_replacement
    request
    frame = @receiver.input("once")
    @connection.incoming << frame
    assert_equal ["once"], @stream.poll.data
    @connection.sent.clear
    @connection.writable = false
    @stream.acknowledge_input(4)
    @connection.incoming << frame
    assert_raises(Rho::Env::Error) { @stream.poll }
    @connection.connection_id = "replacement"
    @connection.writable = true
    @receiver = Stream::Receiver.new
    request
    assert_empty @connection.sent
    @connection.incoming << @receiver.input("fresh")
    assert_equal ["fresh"], @stream.poll.data
    receipt = @receiver.receive(@connection.sent.shift).first
    assert_equal [1, 2], [receipt.id, receipt.sequence]
    @gate.permitted = false
    @stream.acknowledge_input(2)
    assert_empty @connection.sent
    @gate.permitted = true
    assert_empty @stream.poll.data
    assert_empty @connection.sent
  end

  def test_input_and_receipt_bounds_and_permission_fence
    request
    @gate.permitted = false
    @connection.incoming << @receiver.input("denied")
    assert_empty @stream.poll.data
    assert_empty @connection.sent
    @gate.permitted = true
    @connection.incoming << @receiver.input("ok")
    assert_equal ["ok"], @stream.poll.data
    assert_raises(Rho::Env::Error) { @stream.acknowledge_input(3) }
    @stream.acknowledge_input(2)
    assert_raises(Rho::Env::Error) { @stream.acknowledge_input(2) }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode('{"type":"input","id":0,"data":"YQ=="}') }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode('{"type":"receipt","id":1,"sequence":1,"status":"executed","bytes":1}') }
    assert_raises(Rho::Env::Error) { Stream::Protocol.decode('{"type":"receipt","id":1,"sequence":1,"status":"written","bytes":8193}') }
  end

  private

    def request
      @connection.incoming << @receiver.resume
      @stream.poll
    end
end
