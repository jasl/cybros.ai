require "test_helper"

class AgentAPI::V1::DecisionInferenceRequestsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @account.update!(cost_unit: "USD")
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @token = create_access_token_fixture(user: @human, name: "Decision caller")
  end

  test "decision input and questions survive acceptance execution usage and public result" do
    input = { "ticket" => "Duplicate charge", "paid" => false, "amounts" => [12, 12] }
    post path, headers: auth("decision-1"), as: :json, params: payload(input)
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")
    assert_not_nil public_id

    fake_dispatch(json_response(200, provider_response)) do |adapter|
      perform_enqueued_jobs while enqueued_jobs.any?
      assert_equal 1, adapter.requests.length
      wire = JSON.parse(adapter.requests.sole.fetch(:body))
      assert_equal input, wire.dig("input", 0, "content", 0, "data")
      assert_equal questions.as_json, wire.fetch("questions")
    end

    get "#{path}/#{public_id}", headers: auth
    assert_response :success
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal "completed", result.fetch("status")
    assert_equal provider_response.fetch("answers"), result.fetch("answers")
    assert_not result.key?("output_text")
    assert_equal 120, result.dig("usage", "input_tokens")
    assert_equal 0, result.dig("usage", "output_tokens")
    receipt = UsageRecord.find_by!(inference_request_public_id: public_id)
    assert_equal BigDecimal("0.000012"), receipt.cost_amount
    assert_equal "decision", receipt.workload

    post path, headers: auth("decision-1"), as: :json, params: payload(input)
    assert_response :success
    assert_equal public_id, response.parsed_body.dig("inference_request", "public_id")
    changed = payload(input)
    changed[:inference_request][:configuration][:questions][0][:instructions] = "A different question"
    post path, headers: auth("decision-1"), as: :json, params: changed
    assert_response :conflict
  end

  test "TypeSafe maps the same input and preserves output usage" do
    post path, headers: auth("systemone"), as: :json,
      params: payload(["first", { "second" => false }], model: "dev/mock-system-one")
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")
    response_body = { "answers" => { "billing" => { "type" => "noul", "noul" => 0.9 } },
      "usage" => { "input_tokens" => 80, "output_tokens" => 12 } }
    fake_dispatch(json_response(200, response_body)) do |adapter|
      perform_enqueued_jobs while enqueued_jobs.any?
      wire = JSON.parse(adapter.requests.sole.fetch(:body))
      assert_equal ["first", { "second" => false }], wire.fetch("state")
      assert_equal "noul", wire.dig("questions", "billing", "type")
    end
    get "#{path}/#{public_id}", headers: auth
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal provider_response.fetch("answers"), result.fetch("answers")
    assert_equal 12, result.dig("usage", "output_tokens")
  end

  test "missing questions and malformed questions create no work" do
    [[], [{ name: "bad", type: "box", instructions: "Find it" }]].each_with_index do |invalid, index|
      request = payload("evidence")
      request[:inference_request][:configuration] = index.zero? ? {} : { questions: invalid }
      assert_no_difference "InferenceRequest.count" do
        post path, headers: auth("invalid-#{index}"), as: :json, params: request
      end
      assert_response :unprocessable_entity
    end
  end

  test "cancel before admission prevents provider IO and leaves no fabricated answers" do
    post path, headers: auth("cancel"), as: :json, params: payload("evidence")
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")
    post "#{path}/#{public_id}/cancellation", headers: auth, as: :json
    assert_response :success
    fake_dispatch(json_response(200, provider_response)) do |adapter|
      perform_enqueued_jobs while enqueued_jobs.any?
      assert_empty adapter.requests
    end
    get "#{path}/#{public_id}", headers: auth
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal "canceled", result.fetch("status")
    assert_not result.key?("answers")
  end

  test "input estimate includes question instructions without contacting a provider" do
    request = payload("evidence").fetch(:inference_request)
    post "#{path}/input_estimate", headers: auth, as: :json, params: { input_estimate: request }
    assert_response :success
    short_count = response.parsed_body.dig("input_estimate", "input_tokens")
    request[:configuration][:questions][0][:instructions] = "Long question " * 100
    post "#{path}/input_estimate", headers: auth, as: :json, params: { input_estimate: request }
    assert_response :success
    assert_operator response.parsed_body.dig("input_estimate", "input_tokens"), :>, short_count
  end

  test "internal create preserves mixed decisions and a per-question refusal" do
    mixed = questions + [
      { name: "allowed", type: "choice", instructions: "Is this allowed?",
        choices: [{ value: true, description: "Allowed" }, { value: false, description: "Denied" }] },
      { name: "urgency", type: "score", instructions: "Rate urgency",
        levels: [{ label: "low", description: "Can wait" }, { label: "high", description: "Today" }] },
      { name: "restricted", type: "predicate", instructions: "Restricted question" },
    ]
    command = InferenceRequests::Create::Command.new(
      workspace: @workspace, creating_user: @human, workload: "decision",
      submitted: DevModelLane.submission_for("decision", model: "dev/mock-decision"), configuration: { questions: mixed },
      input: "Evidence", upload_public_ids: [], billing_subject: nil, idempotency_key: "internal-decision"
    )
    created = InferenceRequests::Create.call(command: command, port: DevModelLane.port)
    assert_predicate created, :created?
    shared = Nexus::Contract.pack.fetch("inference_requests.json").dig("valid_decision_fixture", "inference_request", "result")
    provider = { "answers" => shared.fetch("answers"), "usage" => { "input_tokens" => 120, "output_tokens" => 0 } }
    fake_dispatch(json_response(200, provider)) do
      ModelInvocations::AdmitQueuedWork.call
      perform_enqueued_jobs while enqueued_jobs.any?
    end
    get "#{path}/#{created.accepted.fetch("inference_request_public_id")}", headers: auth
    assert_response :success
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal "completed", result.fetch("status")
    assert_equal shared.fetch("answers"), result.fetch("answers")
    assert_not result.key?("error")
  end

  private

    def path = "/agent_api/v1/workspaces/#{@workspace.public_id}/inference_requests"

    def auth(key = nil)
      { "Authorization" => "Bearer #{@token.secret}" }.tap { |headers| headers["Idempotency-Key"] = key if key }
    end

    def questions
      [{ name: "billing", type: "predicate", instructions: "Is this about billing?" }]
    end

    def payload(input, model: "dev/mock-decision")
      { inference_request: { workload: "decision", model: { model: model }, input: input,
        configuration: { questions: questions } } }
    end

    def provider_response
      { "answers" => [{ "name" => "billing", "type" => "predicate", "probability" => 0.9 }],
        "usage" => { "input_tokens" => 120, "output_tokens" => 0 } }
    end
end
