require "test_helper"

class AgentAPI::V1::WorkAnalysesTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @token = create_access_token_fixture(user: @human, name: "Work analysis")
    @headers = { "Authorization" => "Bearer #{@token.secret}" }
    @window = { from: "2026-10-10T12:15:30Z", to: "2026-10-12T12:15:30Z" }
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human, answering_user: users(:agent))
    @run = Run.create!(workspace: workspaces(:shared), creating_user: @human,
      status: "running", approval_mode: "bypass", created_at: Time.utc(2026, 10, 11))
    UsageRecord.create!(account: @human.account, idempotency_key: SecureRandom.uuid_v7,
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      conversation_public_id: @conversation.public_id, consumer_user_public_id: @human.public_id,
      provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text", workload: "text_generation",
      purpose: "task", service_class: "interactive", admission_shape: "priced", status: "succeeded",
      recorded_at: Time.utc(2026, 10, 11), total_tokens: 12, duration_ms: 0, cost_amount: "0", cost_unit: "USD")
  end

  test "analysis exposes exact public metrics and model filters leave execution unchanged" do
    get "/agent_api/v1/work_analysis", headers: @headers, params: @window
    assert_response :success
    analysis = response.parsed_body.fetch("analysis")
    assert_equal "2026-10-10T12:15:30.000000Z", analysis.fetch("from")
    assert_equal "2026-10-12T12:15:30.000000Z", analysis.fetch("to")
    assert analysis.fetch("as_of")
    assert_nil analysis.fetch("workspace_public_id")
    assert_nil analysis.fetch("agent_public_id")
    assert_equal 1, analysis.dig("model_usage", "totals", "request_count")
    assert_equal 1, analysis.dig("model_usage", "totals", "amount_sample_count")
    assert_equal "0.0", analysis.dig("model_usage", "totals", "cost_amount")
    assert_equal({ "sample_count" => 1, "missing_count" => 0, "p50" => 0, "p95" => 0 }, analysis.dig("model_usage", "latency", "duration_ms"))
    assert_equal "dev", analysis.dig("model_usage", "breakdown", "groups", 0, "value")
    assert_equal 1, analysis.dig("execution", "run_count")
    assert_equal 0, analysis.dig("execution", "tools", "task_count")
    assert_not_includes response.body, @run.public_id
    assert_not_includes response.body, @conversation.public_id
    assert_not_includes response.body, "account_id"
    assert_not analysis.key?("unit")

    get "/agent_api/v1/work_analysis", headers: @headers, params: @window.merge(status: "failed")
    assert_response :success
    assert_equal 0, response.parsed_body.dig("analysis", "model_usage", "totals", "request_count")
    assert_equal 1, response.parsed_body.dig("analysis", "execution", "run_count")
  end

  test "member scope, explicit group parameters, and UTC defaults use the ordinary query boundary" do
    get "/agent_api/v1/work_analysis", headers: @headers,
      params: @window.merge(group_by: "catalog_model_ref", rank_by: "cost_amount", limit: 1,
        workspace_public_id: workspaces(:shared).public_id, agent_public_id: users(:agent).public_id)
    assert_response :success
    assert_equal users(:agent).public_id, response.parsed_body.dig("analysis", "agent_public_id")
    assert_equal workspaces(:shared).public_id, response.parsed_body.dig("analysis", "workspace_public_id")
    assert_equal "catalog_model_ref", response.parsed_body.dig("analysis", "model_usage", "breakdown", "group_by")
    assert_equal "cost_amount", response.parsed_body.dig("analysis", "model_usage", "breakdown", "rank_by")
    assert_equal 1, response.parsed_body.dig("analysis", "model_usage", "breakdown", "limit")
    assert_equal 0, response.parsed_body.dig("analysis", "model_usage", "totals", "request_count"), "Human trial consumer is not the Agent"
    get "/agent_api/v1/work_analysis", headers: @headers, params: @window.merge(workspace_public_id: workspaces(:personal).public_id)
    assert_response :not_found
    get "/agent_api/v1/work_analysis", headers: @headers, params: @window.merge(agent_public_id: @human.public_id)
    assert_response :not_found
    travel_to Time.utc(2026, 10, 16, 15) do
      get "/agent_api/v1/work_analysis", headers: @headers
      assert_response :success
      assert_equal "2026-10-09T00:00:00.000000Z", response.parsed_body.dig("analysis", "from")
      assert_equal "2026-10-16T00:00:00.000000Z", response.parsed_body.dig("analysis", "to")
    end
  end

  test "fractional UTC bounds round-trip the actual SQL window" do
    get "/agent_api/v1/work_analysis", headers: @headers,
      params: { from: "2026-10-11T08:00:00.000001+08:00", to: "2026-10-11T08:00:01.123456+08:00" }
    assert_response :success
    analysis = response.parsed_body.fetch("analysis")
    assert_equal "2026-10-11T00:00:00.000001Z", analysis.fetch("from")
    assert_equal "2026-10-11T00:00:01.123456Z", analysis.fetch("to")
    assert_equal 0, analysis.dig("model_usage", "totals", "request_count"), "midnight receipt is outside the exact window"
  end

  test "present grouping options must be scalars rather than silently defaulting" do
    { group_by: "status", rank_by: "cost_amount", limit: "1" }.each do |field, value|
      [[value], { value: value }].each do |malformed|
        get "/agent_api/v1/work_analysis", headers: @headers, params: @window.merge(field => malformed)
        assert_response :bad_request
      end
    end
  end

  test "over-wide and unsupported queries refuse and other credential planes cannot enter" do
    [{ to: "2027-01-15T12:15:30Z" }, { to: @window[:from] }, { group_by: "payer_user_public_id" },
      { rank_by: "duration_ms" }, { limit: 0 }, { limit: 51 }, { limit: "many" }, { unit: "day" },
      { provider_id: ["dev"] }, { status: %w[succeeded failed] }].each do |overrides|
      get "/agent_api/v1/work_analysis", headers: @headers, params: @window.merge(overrides)
      assert_response :bad_request
    end
    sign_in_as @human
    get "/agent_api/v1/work_analysis", params: @window
    assert_response :unauthorized
    platform = create_access_token_fixture(user: users(:owner), name: "Platform analysis", plane: :platform)
    get "/agent_api/v1/work_analysis", params: @window, headers: { "Authorization" => "Bearer #{platform.secret}" }
    assert_response :unauthorized
  end
end
