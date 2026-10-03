require "test_helper"

class ApiExecutorClaimStatusTest < Minitest::Test
  TASK_PATH = "/agent_api/v1/executor/inbox/loop-1/task-1".freeze

  def test_a_claim_read_keeps_its_proof_in_the_header_and_returns_the_current_boolean
    context = task([[200, {}, { "claim" => { "active" => true } }],
                    [200, {}, { "claim" => { "active" => false } }]])
    active = context.claim_status(claim_token: "claim-proof")
    inactive = context.claim_status(claim_token: "claim-proof")

    assert_instance_of CybrosAgent::Api::ClaimStatus, active
    assert_predicate active, :active?
    refute_predicate inactive, :active?
    assert_equal({ active: true }, active.to_h)
    assert_equal({ active: false }, inactive.to_h)
    assert_equal 2, @transport.requests.length
    @transport.requests.each do |request|
      assert_equal :get, request.fetch(:method)
      assert_equal "#{TASK_PATH}/claim", request.fetch(:path)
      assert_equal({ "Claim-Token" => "claim-proof" }, request.fetch(:headers))
      assert_equal "executor-credential", request.fetch(:credential)
      assert_nil request.fetch(:body)
      assert_nil request.fetch(:params)
      assert_equal 30, request.fetch(:timeout)
    end
  end

  def test_a_missing_or_nonboolean_active_field_is_never_read_as_inactive
    [nil, {}, { "claim" => nil }, { "claim" => {} },
      { "claim" => { "active" => nil } }, { "claim" => { "active" => "false" } }].each do |body|
      context = task([[200, {}, body]])

      assert_raises(CybrosAgent::Api::MalformedResponse) { context.claim_status(claim_token: "claim-proof") }
      assert_equal 1, @transport.requests.length
    end
  end

  def test_refusals_and_read_failures_keep_the_existing_failure_ladder_without_retry
    [
      [404, {}, nil, CybrosAgent::Api::NotFound],
      [409, {}, { "error" => { "code" => "not_claimant", "message" => "Refused" } }, CybrosAgent::Api::Conflict],
      [401, {}, nil, CybrosAgent::Api::Unauthorized],
      [429, { "Retry-After" => "17" }, nil, CybrosAgent::Api::RateLimited],
      [503, {}, "upstream unavailable", CybrosAgent::Api::ServerError],
    ].each do |status, headers, body, error_class|
      context = task([[status, headers, body]])

      error = assert_raises(error_class) { context.claim_status(claim_token: "claim-proof") }
      assert_equal "not_claimant", error.code if status == 409
      assert_equal 17, error.retry_after if status == 429
      assert_equal 1, @transport.requests.length
    end

    context = task([:connection_error])
    assert_raises(CybrosAgent::TransportError) { context.claim_status(claim_token: "claim-proof") }
    assert_equal 1, @transport.requests.length
  end

  def test_each_read_uses_the_original_credential_provider_and_propagates_its_failure
    reads = 0
    failure = CybrosAgent::Credentials::NotDurable.new("credential could not be saved")
    provider = lambda do
      reads += 1
      raise failure if reads == 1

      "renewed-executor-credential"
    end
    context = task([[200, {}, { "claim" => { "active" => true } }]], credential_provider: provider)

    raised = assert_raises(CybrosAgent::Credentials::NotDurable) do
      context.claim_status(claim_token: "claim-proof")
    end
    assert_same failure, raised
    assert_empty @transport.requests
    assert_predicate context.claim_status(claim_token: "claim-proof"), :active?
    assert_equal 2, reads
    assert_equal "renewed-executor-credential", @transport.requests.first.fetch(:credential)
  end

  def test_an_empty_claim_token_is_refused_before_transport
    context = task([])

    error = assert_raises(ArgumentError) { context.claim_status(claim_token: "") }
    assert_equal "claim_token must be a nonempty String", error.message
    assert_empty @transport.requests
  end

  def test_the_existing_extension_budget_guard_still_rejects_coercible_nonintegers
    context = task([])
    [0, -1, 1.0, "1000", nil].each do |value|
      if ENV["RBS_TEST_TARGET"] && ![0, -1].include?(value)
        assert_raises(RBS::Test::Tester::TypeError) { context.extend(claim_token: "claim-proof", timeout_ms: value) }
      else
        assert_raises(ArgumentError) { context.extend(claim_token: "claim-proof", timeout_ms: value) }
      end
    end
    assert_empty @transport.requests
  end

  private

    def task(script, credential_provider: nil)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      options = credential_provider ? { credential_provider: credential_provider } : { credential: "executor-credential" }
      client = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: @transport, **options)
      client.inbox_task(agent_loop_public_id: "loop-1", task_key: "task-1")
    end
end
