require "test_helper"
require "timeout"

class RunnerClaimRealtimeTest < Minitest::Test
  class Transport
    attr_accessor :response_status, :state, :delay, :reply, :now
    attr_reader :requests

    def initialize
      @requests = []
      @response_status = 200
      @state = "waiting"
      @now = 100.0
      @delay = 0.0
      @connection_id = nil
    end

    def call(path, **request)
      @requests << request.merge(path: path, thread: Thread.current)
      @now += @delay
      raise @reply if @reply

      if request[:method] == :put
        @connection_id = request.fetch(:body).fetch("connection_id")
      end
      body = { "realtime" => { "status" => @state, "reason" => nil, "connection_id" => @connection_id,
        "offer_sdp" => "offer", "answer_sdp" => "answer", "max_age_ms" => @state == "active" ? 1000 : 0 } }
      CybrosAgent::Response.new(status: @response_status, headers: { "Retry-After" => "3" }, body: body)
    end
  end

  class Log
    def warn(*, **) = nil
  end

  def setup
    @transport = Transport.new
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", credential: "executor", transport: @transport)
    task = executor.inbox_task(run_public_id: "run", task_key: "task")
    @bridge = Rho::Runner::ClaimRealtime.new(task: task, claim_token: "original", clock: -> { @transport.now }, log: Log.new)
    @context = Rho::Runner::ExecutionContext.new(realtime: @bridge)
  end

  def test_no_http_until_handler_explicitly_offers_and_all_io_stays_on_control_thread
    assert_nil @bridge.wait
    @bridge.flush
    refute @bridge.allowed?
    assert_empty @transport.requests
    offer
    assert_equal [:get, :put], @transport.requests.map { |request| request.fetch(:method) }
    assert @transport.requests.all? { |request| request.fetch(:thread) == Thread.current }
    assert @transport.requests.all? { |request| request.fetch(:headers) == { "Claim-Token" => "original" } }
    refute @bridge.allowed?
    activate
    assert @bridge.allowed?
  end

  def test_unknown_http_expires_permission_without_canceling_execution_and_fresh_projection_recovers
    offer
    activate
    @transport.reply = CybrosAgent::TransportError.new("offline")
    @transport.now += 0.5
    @bridge.flush
    assert @bridge.allowed?
    @transport.now += 0.5
    refute @bridge.allowed?
    refute @context.cancelled?
    @transport.reply = nil
    @bridge.flush
    assert @bridge.allowed?
  end

  def test_a_late_response_never_renews_from_receive_time
    offer
    @transport.state = "active"
    @transport.now += 0.5
    @transport.delay = 1.1
    @bridge.flush
    refute @bridge.allowed?
    refute @context.cancelled?
  end

  def test_observed_permission_can_only_spend_the_remaining_original_window
    assert_equal 0, @bridge.remaining_ms
    offer
    activate
    assert_equal 1000, @bridge.remaining_ms
    @transport.now += 0.25
    assert_equal 750, @bridge.remaining_ms
    @transport.now += 0.75
    assert_equal 0, @bridge.remaining_ms
    @bridge.flush
    assert_equal 1000, @bridge.remaining_ms
    @bridge.close
    assert_equal 0, @bridge.remaining_ms
  end

  def test_pause_disables_input_but_explicit_close_sticks_until_a_new_offer
    offer
    activate
    @transport.state = "paused"
    @transport.now += 0.5
    @bridge.flush
    refute @bridge.allowed?
    activate
    assert @bridge.allowed?
    previous = @bridge.snapshot.connection_id
    @transport.state = "closed"
    @transport.now += 0.5
    @bridge.flush
    refute @bridge.allowed?
    refute @context.cancelled?
    assert_nil @bridge.wait
    assert @bridge.closed?
    assert_raises(Rho::Runner::ClaimRealtime::Closed) { @bridge.offer(sdp: "offer", reopen: false) }
    @transport.state = "waiting"
    offer
    refute_equal previous, @bridge.snapshot.connection_id
    assert_equal previous, @transport.requests.last.fetch(:body).fetch("previous_connection_id")
    activate
    assert @bridge.allowed?
  end

  def test_cancellation_closes_gate_and_a_late_read_cannot_restore_it
    offer
    activate
    @context.cancel(:canceled)
    refute @bridge.allowed?
    @transport.now += 0.5
    before = @transport.requests.size
    @context.renew!
    assert_equal before, @transport.requests.size
    assert_nil @bridge.wait
  end

  def test_http_refusal_closes_a_peer_but_a_throttle_only_uses_the_remaining_window
    offer
    activate
    @transport.response_status = 429
    @transport.now += 0.5
    @bridge.flush
    assert @bridge.allowed?
    assert_equal 3, @bridge.wait
    @transport.now += 0.5
    refute @bridge.allowed?
    @transport.response_status = 401
    @transport.now += 2.5
    @bridge.flush
    assert_nil @bridge.wait
    refute @context.cancelled?
  end

  def test_queued_input_cannot_cross_an_expired_or_paused_permission_window
    offer
    activate
    @transport.now += 0.2
    assert @bridge.received_allowed?(age: 0.1)
    @transport.now += 1.0
    @bridge.flush
    refute @bridge.received_allowed?(age: 0.5)
    @transport.now += 0.2
    assert @bridge.received_allowed?(age: 0.1)
    @transport.state = "paused"
    @transport.now += 0.5
    @bridge.flush
    refute @bridge.received_allowed?(age: 0)
    activate
    refute @bridge.received_allowed?(age: 0.1)
  end

  private

    def offer
      worker = Thread.new { Rho::Runner::ExecutionContext.with(@context) { @bridge.offer(sdp: "offer") } }
      Timeout.timeout(2) { Thread.pass until @bridge.wait == 0.0 }
      @bridge.flush
      worker.value
    ensure
      if worker&.alive?
        @context.cancel(:canceled)
        worker.join
      end
    end

    def activate
      @transport.state = "active"
      @transport.now += 0.5
      @bridge.flush
    end
end
