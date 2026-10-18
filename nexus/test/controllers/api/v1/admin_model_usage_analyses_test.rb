require "test_helper"

class API::V1::AdminModelUsageAnalysesTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_access_token_fixture(user: users(:owner), name: "Account analysis", plane: :platform)
    @headers = { "Authorization" => "Bearer #{@admin.secret}" }
    @window = { from: "2026-10-10T00:00:00Z", to: "2026-10-12T00:00:00Z" }
    @receipt = UsageRecord.create!(account: accounts(:cybros), idempotency_key: SecureRandom.uuid_v7,
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1, consumer_user_public_id: users(:member).public_id,
      provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text", workload: "text_generation",
      purpose: "task", service_class: "interactive", admission_shape: "priced", status: "failed",
      recorded_at: Time.utc(2026, 10, 11), total_tokens: 25)
  end

  test "the Account analysis is aggregate-only and unknown amounts remain distinguishable" do
    get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window.merge(group_by: "status")
    assert_response :success
    analysis = response.parsed_body.fetch("analysis")
    assert_equal 1, analysis.dig("model_usage", "totals", "request_count")
    assert_equal 25, analysis.dig("model_usage", "totals", "total_tokens")
    assert_equal true, analysis.dig("model_usage", "totals", "cost_complete")
    assert_equal 0, analysis.dig("model_usage", "totals", "amount_sample_count")
    assert_equal "failed", analysis.dig("model_usage", "breakdown", "groups", 0, "value")
    assert_nil analysis.dig("model_usage", "latency", "duration_ms", "p50")
    assert_not analysis.key?("execution")
    assert_not analysis.key?("workspace_public_id")
    assert_not analysis.key?("agent_public_id")
    assert_not_includes response.body, users(:member).public_id
    assert_not_includes response.body, @receipt.public_id
    assert_not_includes response.body, "account_id"
  end

  test "member selectors and unknown dimensions refuse instead of widening to Account totals" do
    %w[workspace_public_id agent_public_id consumer_user_public_id payer_user_public_id billing_subject_key provider].each do |key|
      get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window.merge(key => "activity")
      assert_response :bad_request
      assert_equal "filter_unsupported", response.parsed_body.dig("error", "code")
    end
    get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window.merge(status: %w[succeeded failed])
    assert_response :bad_request
    get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window.merge(to: "2027-01-15T00:00:00Z")
    assert_response :bad_request
    assert_equal "window_too_wide", response.parsed_body.dig("error", "code")
  end

  test "only a current Human administrator can read Account analysis" do
    member = create_access_token_fixture(user: users(:member), name: "Member settings", plane: :platform)
    get "/api/v1/admin/model_usage/analysis", headers: { "Authorization" => "Bearer #{member.secret}" }, params: @window
    assert_response :forbidden
    agent = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    get "/api/v1/admin/model_usage/analysis", headers: { "Authorization" => "Bearer #{agent.access_secret}" }, params: @window
    assert_response :unauthorized
    users(:owner).update!(status: "suspended")
    get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window
    assert_response :unauthorized
  end

  test "grouping options reject structured values" do
    { group_by: ["status"], rank_by: { value: "cost_amount" }, limit: ["0"] }.each do |field, value|
      get "/api/v1/admin/model_usage/analysis", headers: @headers, params: @window.merge(field => value)
      assert_response :bad_request
    end
  end
end
