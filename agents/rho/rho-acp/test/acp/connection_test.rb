require "test_helper"
require "rho/acp"

# THE TWO-WAY LOOP: one connection per wire, both roles at once — outbound requests with
# ids of our own awaiting the peer's response, inbound requests handed to the drainer
# with a way to answer later, notifications, and `$/cancel_request` in BOTH directions:
# `Pending#cancel` sends the notice for a request we issued (the peer then answers
# -32800 or a result), and the peer's notice marks OUR inbound request cancelled for
# whoever holds it. The READER THREAD ONLY PARSES — it resolves pendings and flags
# cancels, and never runs a handler; the caller drains with `receive`/`run`. EOF (either
# way) closes cleanly: `receive` answers nil, every waiting `Pending` raises `Closed`.
class AcpConnectionTest < Minitest::Test
  Wire = Rho::Acp::Wire
  Connection = Rho::Acp::Connection

  def setup
    a_reads, b_writes = IO.pipe
    b_reads, a_writes = IO.pipe
    @a = Connection.new(Wire.new(input: a_reads, output: a_writes))
    @b = Connection.new(Wire.new(input: b_reads, output: b_writes))
  end

  def teardown
    @a.close
    @b.close
  end

  def test_an_outbound_request_is_answered_by_the_peer_by_id
    pending = @a.request("initialize", { "protocolVersion" => 1 })

    inbound = @b.receive(timeout: 2)
    assert_instance_of Connection::Inbound, inbound
    assert_equal [0, "initialize", { "protocolVersion" => 1 }], [inbound.id, inbound.method, inbound.params]
    refute inbound.answered?
    inbound.respond({ "protocolVersion" => 1, "agentCapabilities" => {} })
    assert inbound.answered?

    assert_equal({ "protocolVersion" => 1, "agentCapabilities" => {} }, pending.wait(timeout: 2))
    assert pending.done?
  end

  def test_ids_count_up_per_direction_and_interleaved_requests_both_ways_resolve_by_id
    a_first = @a.request("session/new", { "cwd" => "/p" })
    b_first = @b.request("session/request_permission", { "toolCall" => { "toolCallId" => "t" } })
    a_second = @a.request("session/prompt", { "prompt" => [] })

    assert_equal [0, 1], [a_first.id, a_second.id]
    assert_equal 0, b_first.id

    to_b = [@b.receive(timeout: 2), @b.receive(timeout: 2)]
    to_a = @a.receive(timeout: 2)
    assert_equal %w[session/new session/prompt], to_b.map(&:method)
    assert_equal "session/request_permission", to_a.method

    to_b[1].respond({ "stopReason" => "end_turn" })
    to_a.respond({ "outcome" => { "outcome" => "cancelled" } })
    to_b[0].respond({ "sessionId" => "s" })

    assert_equal({ "sessionId" => "s" }, a_first.wait(timeout: 2))
    assert_equal({ "stopReason" => "end_turn" }, a_second.wait(timeout: 2))
    assert_equal({ "outcome" => { "outcome" => "cancelled" } }, b_first.wait(timeout: 2))
  end

  def test_a_notification_is_delivered_without_an_id_and_is_not_answerable
    @a.notify("session/update", { "sessionId" => "s", "update" => { "sessionUpdate" => "plan" } })
    @a.notify("session/cancel")

    first = @b.receive(timeout: 2)
    assert_instance_of Wire::Notification, first
    assert_equal ["session/update", { "sessionId" => "s", "update" => { "sessionUpdate" => "plan" } }],
      [first.method, first.params]
    second = @b.receive(timeout: 2)
    assert_equal "session/cancel", second.method
    assert_nil second.params
  end

  def test_a_null_result_resolves_the_pending_with_nil
    pending = @a.request("fs/write_text_file", { "path" => "/p" })
    @b.receive(timeout: 2).respond(nil)

    assert_nil pending.wait(timeout: 2)
    assert pending.done?
  end

  def test_the_peers_error_raises_remote_error_carrying_code_message_and_data
    pending = @a.request("session/new", { "cwd" => "relative" })
    @b.receive(timeout: 2).fail(-32602, "cwd must be absolute", data: { "cwd" => "relative" })

    error = assert_raises(Rho::Acp::RemoteError) { pending.wait(timeout: 2) }
    assert_equal [-32602, "cwd must be absolute", { "cwd" => "relative" }], [error.code, error.message, error.data]
    assert pending.done?
  end

  def test_waiting_past_the_timeout_raises_unanswered_and_the_pending_stays_open
    pending = @a.request("session/prompt", {})

    assert_raises(Rho::Acp::Unanswered) { pending.wait(timeout: 0.05) }
    refute pending.done?
    @b.receive(timeout: 2).respond({ "stopReason" => "end_turn" })
    assert_equal({ "stopReason" => "end_turn" }, pending.wait(timeout: 2))
  end

  # OUTBOUND CANCEL: our notice goes out as `$/cancel_request {requestId}`;
  # the peer's holder sees `cancelled?` and its `on_cancel` hook fires; the
  # -32800 it answers resolves the pending as a RemoteError of that code.
  def test_cancelling_our_request_notifies_the_peer_and_marks_their_inbound
    pending = @a.request("session/request_permission", { "toolCall" => { "toolCallId" => "t" } })
    inbound = @b.receive(timeout: 2)
    fired = Queue.new
    inbound.on_cancel { fired << :fired }
    refute inbound.cancelled?

    pending.cancel
    assert pending.cancelled?
    assert_equal :fired, fired.pop(timeout: 2)
    assert inbound.cancelled?
    inbound.fail_cancelled

    error = assert_raises(Rho::Acp::RemoteError) { pending.wait(timeout: 2) }
    assert_equal [-32800, "Request cancelled"], [error.code, error.message]
    assert_nil @b.receive(timeout: 0.1), "the cancel notice is protocol-level, never an event for the drainer"
  end

  def test_a_cancel_that_lands_before_the_drain_is_seen_at_receive_and_a_late_hook_fires_at_once
    pending = @a.request("session/prompt", {})
    pending.cancel
    sleep 0.1

    inbound = @b.receive(timeout: 2)
    assert inbound.cancelled?
    fired = false
    inbound.on_cancel { fired = true }
    assert fired, "a hook registered after the cancel runs immediately"
  end

  def test_a_cancelled_request_may_still_be_answered_with_a_result
    pending = @a.request("session/prompt", {})
    inbound = @b.receive(timeout: 2)
    pending.cancel
    inbound.respond({ "stopReason" => "cancelled" })

    assert_equal({ "stopReason" => "cancelled" }, pending.wait(timeout: 2))
  end

  def test_a_cancel_for_an_unknown_or_answered_id_is_ignored
    pending = @a.request("m", {})
    inbound = @b.receive(timeout: 2)
    inbound.respond({})
    pending.wait(timeout: 2)
    @a.notify("$/cancel_request", { "requestId" => inbound.id })
    @a.notify("$/cancel_request", { "requestId" => 99 })
    @a.notify("$/cancel_request", {})
    @a.notify("ping")

    refute inbound.cancelled?
    assert_equal "ping", @b.receive(timeout: 2).method
  end

  def test_answering_twice_is_refused
    @a.request("m", {})
    inbound = @b.receive(timeout: 2)
    inbound.respond({})

    assert_raises(Rho::Acp::Error) { inbound.respond({}) }
    assert_raises(Rho::Acp::Error) { inbound.fail(-32603, "x") }
  end

  def test_a_response_to_a_request_we_never_sent_is_dropped
    @b.instance_variable_get(:@wire).write_result(77, { "stray" => true })
    @b.instance_variable_get(:@wire).write_error(78, -32603, "stray")
    @b.notify("ping")

    assert_equal "ping", @a.receive(timeout: 2).method
    refute @a.closed?
  end

  def test_the_peers_eof_closes_the_connection_and_fails_every_waiting_pending
    pending = @a.request("session/prompt", {})
    @b.close

    assert_nil @a.receive(timeout: 2)
    assert @a.closed?
    assert_raises(Rho::Acp::Closed) { pending.wait(timeout: 2) }
    assert_raises(Rho::Acp::Closed) { @a.request("m", {}) }
    assert_raises(Rho::Acp::Closed) { @a.notify("m", {}) }
    assert_nil @a.receive(timeout: 0.1)
  end

  def test_our_own_close_ends_the_reader_and_is_idempotent
    @a.close
    @a.close

    assert @a.closed?
    assert_nil @a.receive
    assert_nil @b.receive(timeout: 2)
    assert @b.closed?
  end

  def test_receive_without_events_returns_nil_at_the_timeout_and_the_connection_stays_open
    assert_nil @a.receive(timeout: 0.05)
    refute @a.closed?
  end

  # THE DRAIN LOOP: `run` hands every event to the block on the caller's
  # thread until the connection closes; a handler that raises on a
  # request answers -32603 with the exception's sentence, so the peer is
  # never left waiting, and the loop goes on.
  def test_run_dispatches_on_the_callers_thread_answers_internal_error_when_the_handler_raises_and_ends_at_close
    seen = Queue.new
    drainer = Thread.new do
      @b.run do |event|
        seen << [Thread.current, event.method]
        case event
        when Connection::Inbound
          raise "boom" if event.method == "explode"

          event.respond({ "ok" => event.method })
        else nil
        end
      end
      :ended
    end

    assert_equal({ "ok" => "m" }, @a.request("m", {}).wait(timeout: 2))
    error = assert_raises(Rho::Acp::RemoteError) { @a.request("explode", {}).wait(timeout: 2) }
    assert_equal(-32603, error.code)
    assert_includes error.message, "boom"
    assert_equal({ "ok" => "again" }, @a.request("again", {}).wait(timeout: 2))
    @a.notify("note", {})
    @a.close

    assert_equal :ended, drainer.value
    events = Array.new(4) { seen.pop(timeout: 2) }
    assert_equal [drainer] * 4, events.map(&:first)
    assert_equal %w[m explode again note], events.map(&:last)
  end

  # ANSWER LATER: the drainer may hand an inbound request to another
  # thread (the park thread of `rho acp`) and move on; `run` never answers
  # on its behalf, and the peer's wait is the peer's.
  def test_a_request_may_be_answered_later_from_another_thread_while_the_drain_goes_on
    parked = Queue.new
    drainer = Thread.new do
      @b.run do |event|
        next unless event.is_a?(Connection::Inbound)

        event.method == "park" ? parked << event : event.respond({ "quick" => true })
      end
    end

    slow = @a.request("park", {})
    assert_equal({ "quick" => true }, @a.request("m", {}).wait(timeout: 2))
    assert_raises(Rho::Acp::Unanswered) { slow.wait(timeout: 0.1) }
    Thread.new { parked.pop.respond({ "late" => true }) }.join(2)
    assert_equal({ "late" => true }, slow.wait(timeout: 2))
  ensure
    @b.close
    drainer&.join(2)
  end

  def test_many_threads_may_request_at_once_and_each_gets_its_own_answer
    drainer = Thread.new { @b.run { |event| event.respond({ "n" => event.params.fetch("n") }) if event.is_a?(Connection::Inbound) } }
    results = Array.new(20) { |n| Thread.new { @a.request("m", { "n" => n }).wait(timeout: 5).fetch("n") } }.map(&:value)

    assert_equal (0...20).to_a, results
  ensure
    @b.close
    drainer&.join(2)
  end

  def test_the_wire_answers_a_malformed_line_under_the_connection_without_disturbing_it
    @b.instance_variable_get(:@wire).instance_variable_get(:@output).write("garbage\n")
    @b.notify("ping")

    assert_equal "ping", @a.receive(timeout: 2).method
    frame = @b.receive(timeout: 2)
    assert_nil frame, "the -32700 answer is a response to no request of ours: dropped, not an event"
    refute @b.closed?
  end
end
