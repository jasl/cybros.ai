require "test_helper"
require "rho/env/webrtc_connection"
require "timeout"

class WebrtcConnectionTest < Minitest::Test
  class Task
    attr_accessor :state, :answer, :error, :offer_error
    attr_reader :offers, :previous

    def initialize
      @state = "active"
      @answer = "answer"
      @offers = []
      @id = nil
    end

    def task_key = "task"

    def realtime(**)
      raise @error if @error

      CybrosAgent::Api::TaskRealtime.new(status: @state, reason: nil, connection_id: @id,
        offer_sdp: "offer", answer_sdp: @answer, max_age_ms: 1000)
    end

    def offer_realtime(connection_id:, previous_connection_id:, **)
      @previous = previous_connection_id
      @offers << connection_id
      @id = connection_id
      raise @offer_error if @offer_error

      realtime
    end
  end

  class Log
    def warn(*, **) = nil
  end

  def setup
    @directory = Dir.mktmpdir("webrtc-recovery")
    @state_path = File.join(@directory, "state")
    File.write(@state_path, "connected")
    executable = File.join(@directory, "peer")
    File.write(executable, <<~SOURCE)
      #!#{RbConfig.ruby}
      require "json"
      $stdout.sync = true
      STDIN.each_line do |line|
        command = JSON.parse(line)
        File.open(#{File.join(@directory, "commands").inspect}, "a") { |file| file.puts(line) }
        result = case command.fetch("op")
        when "offer" then {sdp: "offer"}
        when "poll" then {data: [], state: File.read(#{@state_path.inspect}), ready: true}
        else {}
        end
        puts JSON.generate(result)
      end
    SOURCE
    File.chmod(0o700, executable)
    @now = 100.0
    @task = Task.new
    @gate = Rho::Env::ClaimRealtime.new(task: @task, claim_token: "same", clock: -> { @now }, log: Log.new)
    @context = Rho::Env::ExecutionContext.new(realtime: @gate)
    @connection = Rho::Env::WebrtcConnection.new(executable: executable, context: @context,
      servers: [{ "urls" => ["turn:fixture"] }], clock: -> { @now })
  end

  def teardown
    @connection.close
    FileUtils.remove_entry(@directory)
  end

  def test_failure_uses_relay_without_replaying_input
    assert_equal "connected", poll.state
    previous = @connection.pid
    first_id = @connection.connection_id
    assert @connection.send_bytes("once")
    File.write(@state_path, "disconnected")
    assert_equal "retrying", poll.state
    assert_raises(Errno::ESRCH) { Process.kill(0, previous) }
    refute @connection.send_bytes("dropped")
    assert_equal "retrying", poll.state
    assert_equal 1, @task.offers.size
    @now += 1
    File.write(@state_path, "connected")
    assert_equal "connected", poll.state
    refute_equal first_id, @connection.connection_id
    commands = File.readlines(File.join(@directory, "commands")).map { |line| JSON.parse(line) }
    assert_equal [false, true], commands.select { |c| c["op"] == "offer" }.map { |c| c.fetch("relay") }
    assert_equal [Base64.strict_encode64("once")], commands.select { |c| c["op"] == "send" }.map { |c| c.fetch("data") }
  end

  def test_unanswered_attempts_back_off_and_cancellation_cannot_spawn_again
    @task.answer = nil
    [1, 2, 4, 8, 8].each do |delay|
      assert_equal "answering", poll.state
      pid = @connection.pid
      count = @task.offers.size
      @now += 10
      assert_equal "retrying", poll.state
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      @now += delay - 0.01
      assert_equal "retrying", poll.state
      assert_equal count, @task.offers.size
      @now += 0.01
    end
    @context.cancel
    count = @task.offers.size
    assert_raises(Rho::Env::ExecutionContext::Cancelled) { @connection.poll }
    assert_nil @connection.pid
    assert_equal count, @task.offers.size
  end

  def test_explicit_refusal_stops_retries_but_temporary_control_failure_does_not
    @task.error = CybrosAgent::TransportError.new("offline")
    assert_equal "retrying", poll.state
    refute @gate.closed?
    @now += 1
    @task.error = nil
    assert_equal "connected", poll.state
    @task.state = "closed"
    @now += 0.5
    @gate.flush
    assert @gate.closed?
    assert_equal "closed", poll.state
    count = @task.offers.size
    @task.state = "active"
    @now += 30
    assert_equal "closed", poll.state
    assert_equal count, @task.offers.size
    assert_nil @connection.pid
  end

  def test_lost_offer_response_reconciles_the_accepted_generation
    @task.offer_error = CybrosAgent::TransportError.new("response lost")
    assert_equal "retrying", poll.state
    accepted = @task.offers.last
    @now += 1
    @gate.flush
    refute @gate.closed?
    assert_nil @gate.wait
    @task.offer_error = nil
    assert_equal "connected", poll.state
    assert_equal accepted, @task.previous
    refute_equal accepted, @connection.connection_id
  end

  def test_rate_limit_is_respected_and_invalid_protocol_is_not_retried
    @task.error = CybrosAgent::Api::RateLimited.new(retry_after: 30)
    assert_equal "retrying", poll.state
    @now += 29
    assert_equal "retrying", poll.state
    assert_nil @connection.pid
    @now += 1
    @task.error = CybrosAgent::Api::InvalidRequest.new("bad SDP")
    assert_raises(CybrosAgent::Api::InvalidRequest) { poll }
  end

  private

    def poll
      worker = Thread.new { Rho::Env::ExecutionContext.with(@context) { @connection.poll } }
      Timeout.timeout(3) do
        while worker.alive?
          @gate.flush if @gate.wait == 0.0
          worker.join(0.001)
        end
      end
      worker.value
    ensure
      if worker&.alive?
        @context.cancel
        worker.join
      end
    end
end
