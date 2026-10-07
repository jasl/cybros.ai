require "test_helper"

class ApiExecutorTaskOperationsTest < Minitest::Test
  TASK_PATH = "/agent_api/v1/executor/inbox/run-1/task-1".freeze

  def test_snapshot_preserves_the_durable_trace_order_and_frozen_context
    body = snapshot([operation, observation])
    context = task([[200, {}, body]])
    value = context.operations(claim_token: "proof")

    assert_instance_of CybrosAgent::Api::TaskOperations, value
    assert_equal 2, value.position
    assert_equal [1, 2], value.trace.map(&:position)
    assert_equal %w[operation observation], value.trace.map(&:type)
    assert_equal "read", value.context.tools.first.fetch("name")
    assert_equal({ "model" => "fixture/small" }, value.context.model_defaults)
    assert_predicate value.trace.first, :operation?
    assert_predicate value.trace.last, :observation?
    refute_predicate value.trace.first, :refused?
    assert_equal false, value.trace.last.outcome.fetch("structured_content")
    assert_equal false, value.trace.last.outcome.fetch("is_error")
    assert_raises(FrozenError) { value.context.tools.first["name"] = "write" }
    assert_raises(FrozenError) { value.context.model_defaults["model"] = "changed" }
    assert_predicate value.trace, :frozen?
    assert_predicate value.trace.last.outcome, :frozen?
    assert_request(0, :get, "operations", headers: { "Claim-Token" => "proof" })
  end

  def test_submit_accepts_new_and_replayed_receipts_without_changing_the_request
    context = task([[201, {}, { "operation" => operation }], [200, {}, { "operation" => operation }]])
    request = { "kind" => "tool", "name" => "read", "input" => { "path" => "a.rb" } }
    first = context.submit(claim_token: "proof", key: "call-1", request: request)
    replay = context.submit(claim_token: "proof", key: "call-1", request: request)

    assert_equal first, replay
    assert_equal ["child-1"], first.receipt.fetch("task_keys")
    assert_equal request, first.request
    expected = { "claim_token" => "proof", "operation" => { "key" => "call-1", "request" => request } }
    2.times { |index| assert_request(index, :post, "operations", body: expected) }
    assert_equal 2, @transport.requests.length
  end

  def test_snapshot_pages_carry_the_next_position_without_fetching_a_second_page_implicitly
    first = snapshot([operation])
    first.fetch("operations").merge!("position" => 2, "next_after" => 1)
    last = snapshot([observation])
    last.fetch("operations").merge!("position" => 2, "next_after" => nil)
    context = task([[200, {}, first], [200, {}, last]])
    page = context.operations(claim_token: "proof", after: 0, limit: 1)

    assert_equal 1, page.next_after
    assert_equal 2, page.position
    assert_equal 1, @transport.requests.length
    assert_request(0, :get, "operations", headers: { "Claim-Token" => "proof" }, params: { "after" => 0, "limit" => 1 })
    tail = context.operations(claim_token: "proof", after: page.next_after, limit: 1)
    assert_nil tail.next_after
    assert_equal %w[operation observation], (page.trace + tail.trace).map(&:type)
    assert_request(1, :get, "operations", headers: { "Claim-Token" => "proof" }, params: { "after" => 1, "limit" => 1 })
  end

  def test_a_recorded_refusal_is_a_trace_value_not_a_transport_failure
    refused = operation.except("receipt").merge("refusal" => { "code" => "tool_unavailable", "message" => "Unavailable" })
    context = task([[200, {}, { "operation" => refused }]])
    value = context.submit(claim_token: "proof", key: "call-1", request: refused.fetch("request"))

    assert_predicate value, :refused?
    assert_nil value.receipt
    assert_equal "tool_unavailable", value.refusal.code
    assert_equal "Unavailable", value.refusal.message
    assert_equal refused, JSON.parse(JSON.generate(value.to_h))
  end

  def test_observe_distinguishes_no_available_observation_from_null_or_false_result_data
    null_result = observation.merge("outcome" => observation.fetch("outcome").merge("structured_content" => nil))
    context = task([
      [200, {}, { "observation" => nil, "position" => 1 }],
      [200, {}, { "observation" => null_result, "position" => 2 }],
      [200, {}, { "observation" => observation, "position" => 2 }],
    ])
    waiting = context.observe(claim_token: "proof", after: 1)
    with_null = context.observe(claim_token: "proof", after: 1)
    with_false = context.observe(claim_token: "proof", after: 1)

    assert_predicate waiting, :waiting?
    assert_nil waiting.observation
    assert_equal 1, waiting.position
    refute_predicate with_null, :waiting?
    assert with_null.observation.outcome.key?("structured_content")
    assert_nil with_null.observation.outcome.fetch("structured_content")
    assert_equal null_result, JSON.parse(JSON.generate(with_null.observation.to_h))
    assert_equal false, with_false.observation.outcome.fetch("structured_content")
    assert_equal 2, with_false.position
    3.times { |index| assert_request(index, :post, "observation", body: { "claim_token" => "proof", "after" => 1 }) }
  end

  def test_control_conflicts_are_raised_without_converting_them_to_observations
    %w[not_claimant operation_position_changed operation_mismatch].each do |code|
      context = task([[409, {}, { "error" => { "code" => code, "message" => "Refused" } }]])
      error = assert_raises(CybrosAgent::Api::Conflict) do
        context.submit(claim_token: "proof", key: "call-1", request: operation.fetch("request"))
      end

      assert_equal code, error.code
      assert_equal 1, @transport.requests.length
    end
  end

  def test_transport_loss_is_never_automatically_retried_or_reported_as_waiting
    calls = [
      ->(context) { context.operations(claim_token: "proof") },
      ->(context) { context.submit(claim_token: "proof", key: "call-1", request: operation.fetch("request")) },
      ->(context) { context.observe(claim_token: "proof", after: 0) },
    ]
    calls.each do |call|
      context = task([:connection_error])

      assert_raises(CybrosAgent::TransportError) { call.call(context) }
      assert_equal 1, @transport.requests.length
    end
  end

  def test_missing_trace_or_observation_is_malformed
    context = task([[200, {}, { "operations" => snapshot([]).fetch("operations").except("trace") }]])
    assert_raises(CybrosAgent::Api::MalformedResponse) { context.operations(claim_token: "proof") }
    context = task([[200, {}, { "position" => 0 }]])
    assert_raises(CybrosAgent::Api::MalformedResponse) { context.observe(claim_token: "proof", after: 0) }
  end

  def test_invalid_proof_key_or_position_never_reaches_transport
    context = task([])
    assert_raises(ArgumentError) { context.operations(claim_token: "") }
    assert_raises(ArgumentError) { context.operations(claim_token: "proof", after: -1) }
    assert_raises(ArgumentError) { context.operations(claim_token: "proof", limit: 0) }
    assert_raises(ArgumentError) { context.submit(claim_token: "proof", key: "", request: {}) }
    assert_raises(ArgumentError) { context.observe(claim_token: "proof", after: -1) }
    assert_empty @transport.requests
  end

  private

    def task(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      client = CybrosAgent::ExecutorClient.new(base_url: "https://nexus.test", credential: "executor-credential",
        transport: @transport)
      client.inbox_task(run_public_id: "run-1", task_key: "task-1")
    end

    def assert_request(index, method, suffix, headers: {}, body: nil, params: nil)
      request = @transport.requests.fetch(index)
      assert_equal method, request.fetch(:method)
      assert_equal "#{TASK_PATH}/#{suffix}", request.fetch(:path)
      assert_equal headers, request.fetch(:headers)
      body ? assert_equal(body, request.fetch(:body)) : assert_nil(request.fetch(:body))
      params ? assert_equal(params, request.fetch(:params)) : assert_nil(request.fetch(:params))
      assert_equal "executor-credential", request.fetch(:credential)
      assert_equal 30, request.fetch(:timeout)
    end

    def snapshot(trace)
      { "operations" => {
        "context" => { "tools" => [{ "name" => "read" }], "model_defaults" => { "model" => "fixture/small" } },
        "trace" => trace, "position" => trace.length, "next_after" => nil,
      } }
    end

    def operation
      { "type" => "operation", "position" => 1, "key" => "call-1",
        "request" => { "kind" => "tool", "name" => "read", "input" => { "path" => "a.rb" } },
        "receipt" => { "task_keys" => ["child-1"], "result_task_keys" => ["child-1"], "steps" => [] } }
    end

    def observation
      { "type" => "observation", "position" => 2, "key" => "call-1",
        "outcome" => { "status" => "completed", "is_error" => false, "content" => [], "structured_content" => false } }
    end
end
