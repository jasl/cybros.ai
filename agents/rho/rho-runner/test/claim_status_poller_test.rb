require "test_helper"
require "timeout"

class RunnerClaimStatusPollerTest < Minitest::Test
  class Transport
    attr_reader :requests

    def initialize(&reply)
      @reply = reply
      @requests = []
    end

    def call(path, **request)
      @requests << request.merge(path: path)
      @reply.call
    end
  end

  class Log
    attr_reader :warnings

    def initialize = @warnings = []
    def warn(event, **fields) = @warnings << [event, fields]
  end

  def test_fast_work_never_reads_and_a_due_read_uses_the_original_claim_proof
    poller = build_poller

    assert_equal 5.0, poller.wait
    assert_nil poller.poll
    @now = 104.9
    assert_nil poller.poll
    assert_empty @transport.requests
    @now = 105.0
    assert_equal true, poller.poll
    assert_equal 5.0, poller.wait

    request = @transport.requests.fetch(0)
    assert_equal :get, request.fetch(:method)
    assert_equal "/agent_api/v1/executor/inbox/loop-1/task-1/claim", request.fetch(:path)
    assert_equal({ "Claim-Token" => "original-claim" }, request.fetch(:headers))
    assert_equal "executor-credential", request.fetch(:credential)
    assert_equal 30, request.fetch(:timeout)
    assert_nil request.fetch(:params)
    assert_nil request.fetch(:body)
    assert_empty @log.warnings
  end

  def test_a_large_custom_pool_spreads_its_reads_without_speeding_up_small_pools
    { 1 => 5.0, 8 => 5.0, 25 => 5.0, 100 => 20.0 }.each do |workers, interval|
      poller = build_poller(worker_count: workers)
      assert_equal interval, poller.wait
      @now += interval - 0.01
      assert_nil poller.poll
      assert_empty @transport.requests
      @now += 0.01
      assert_equal true, poller.poll
      assert_equal interval, poller.wait
      assert_equal 1, @transport.requests.length
    end
  end

  def test_a_matching_inactive_claim_cancels_and_an_active_claim_continues
    [true, false].each do |active|
      poller = build_poller(body: { "claim" => { "active" => active } })
      @now += 5

      assert_equal active, poller.poll
      assert_equal 1, @transport.requests.length
      assert_equal 5.0, poller.wait
      assert_empty @log.warnings
    end
  end

  def test_a_disappeared_claim_or_replaced_claim_proof_cancels
    [
      [404, nil],
      [409, { "error" => { "code" => "not_claimant" } }],
    ].each do |status, body|
      poller = build_poller(status: status, body: body)
      @now += 5

      assert_equal false, poller.poll
      assert_equal 1, @transport.requests.length
      assert_empty @log.warnings
    end
  end

  def test_other_conflicts_and_read_failures_are_not_cancellation
    [
      [409, { "error" => { "code" => "other_conflict" } }],
      [401, nil],
      [403, { "error" => { "code" => "not_authorized" } }],
      [500, "upstream unavailable"],
      [200, {}],
      [200, { "claim" => { "active" => "false" } }],
      [204, nil],
    ].each do |status, body|
      poller = build_poller(status: status, body: body)
      @now += 5

      assert_nil poller.poll, "HTTP #{status}: #{body.inspect} is not a cancellation observation"
      assert_equal 1, @transport.requests.length
      assert_equal 5.0, poller.wait
      assert_equal 1, @log.warnings.length
      assert_equal "runner_claim_status_unavailable", @log.warnings.first.first
      assert_equal "task-1", @log.warnings.first.last.fetch(:task)
    end
  end

  def test_a_transport_failure_retains_the_normal_retry_cadence
    poller = build_poller { raise CybrosAgent::TransportError, "connection reset" }
    @now += 5

    assert_nil poller.poll
    assert_equal 5.0, poller.wait
    assert_equal 1, @transport.requests.length
    assert_equal "CybrosAgent::TransportError", @log.warnings.first.last.fetch(:code)
  end

  def test_credential_owner_failures_remain_unknown_without_sending_a_request
    [
      CybrosAgent::Credentials::NotDurable,
      CybrosAgent::Credentials::ConnectionSuperseded,
      CybrosAgent::Credentials::PlaneUnavailable,
      CybrosAgent::DeviceFlow::AuthorizationLostError,
    ].each do |error_class|
      provider = -> { raise error_class, "credential owner refused" }
      poller = build_poller(credential_provider: provider)
      @now += 5

      assert_nil poller.poll
      assert_equal 5.0, poller.wait
      assert_empty @transport.requests
      assert_equal error_class.name, @log.warnings.first.last.fetch(:code)
    end
  end

  def test_a_slow_success_schedules_the_next_read_after_response_completion
    poller = build_poller do
      @now += 7
      response(200, {}, { "claim" => { "active" => true } })
    end
    @now += 5

    assert_equal true, poller.poll
    assert_equal 112.0, @now
    assert_equal 5.0, poller.wait
    assert_nil poller.poll
    assert_equal 1, @transport.requests.length
  end

  def test_api_throttling_records_retry_after_without_sleeping_in_the_control_path
    [2, 17].each do |retry_after|
      poller = build_poller do
        @now += 4
        response(429, { "Retry-After" => retry_after.to_s }, nil)
      end
      assert_backoff(poller, retry_after: retry_after)
      assert_equal 1, @transport.requests.length
      assert_equal "rate_limited", @log.warnings.first.last.fetch(:code)
    end
  end

  def test_credential_throttling_records_retry_after_without_sleeping_or_calling_the_api
    [2, 19].each do |retry_after|
      provider = lambda do
        @now += 4
        raise CybrosAgent::DeviceFlow::RateLimited.new(retry_after: retry_after)
      end
      poller = build_poller(credential_provider: provider)
      assert_backoff(poller, retry_after: retry_after)
      assert_empty @transport.requests
      assert_equal "CybrosAgent::DeviceFlow::RateLimited", @log.warnings.first.last.fetch(:code)
    end
  end

  private

    def build_poller(status: 200, headers: {}, body: { "claim" => { "active" => true } },
                     worker_count: 8, credential_provider: -> { "executor-credential" }, &reply)
      @now = 100.0
      @log = Log.new
      @transport = Transport.new(&(reply || -> { response(status, headers, body) }))
      executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: @transport,
        credential_provider: credential_provider)
      task = executor.inbox_task(agent_loop_public_id: "loop-1", task_key: "task-1")
      Rho::Runner::ClaimStatusPoller.new(task: task, claim_token: "original-claim", worker_count: worker_count,
        clock: -> { @now }, log: @log)
    end

    def response(status, headers, body)
      CybrosAgent::Response.new(status: status, headers: headers, body: body)
    end

    def assert_backoff(poller, retry_after:)
      @now += 5
      assert_nil Timeout.timeout(1) { poller.poll }
      delay = [5.0, retry_after].max
      assert_equal 109.0, @now
      assert_equal delay, poller.wait, "the backoff begins when the bounded request finishes"
      @now += delay - 0.01
      assert_nil poller.poll
      assert_in_delta 0.01, poller.wait
      @now += 0.01
      assert_equal 0.0, poller.wait
    end
end
