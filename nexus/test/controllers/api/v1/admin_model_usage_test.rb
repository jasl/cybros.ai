require "test_helper"

# The statistics consumer's wire (Stage 4 item 7): administrator plane,
# typed rejects, and the service's exactness surfacing end to end.
class API::V1::AdminModelUsageTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_access_token_fixture(user: users(:owner), name: "Ops", plane: :platform)
    @member_token = create_access_token_fixture(user: users(:member), name: "M")
  end

  test "the report answers series and totals over the account's usage" do
    UsageRecord.create!(
      account: accounts(:cybros), idempotency_key: "admin-report:1",
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      consumer_user_public_id: users(:member).public_id,
      provider_id: "dev", catalog_model_ref: "dev/text",
      wire_model_id: "text", workload: "text_generation",
      purpose: "inference_request", service_class: "interactive",
      admission_shape: "priced", status: "succeeded",
      recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100,
      cost_amount: BigDecimal("0.1"), cost_unit: "USD"
    )
    ModelUsageRollups::BackfillHourly.call

    get report_path, headers: bearer(@admin), params: {
      from: "2026-08-21T10:00:00Z", to: "2026-08-21T11:00:00Z",
      workload: "text_generation",
    }
    assert_response :success
    report = response.parsed_body.fetch("report")
    assert_equal "hour", report.fetch("unit")
    assert_equal 1, report.fetch("series").length
    assert_equal 100, report.fetch("totals").fetch("input_tokens")
    assert_equal "0.1", report.fetch("totals").fetch("cost_amount")

    get report_path, headers: bearer(@admin), params: {
      from: "2026-08-21T10:00:00Z", to: "2026-08-21T11:00:00Z", workload: "embedding",
    }
    assert_equal 0, response.parsed_body.dig("report", "totals", "request_count"),
      "the filter cuts to nothing"
  end

  test "malformed windows and times reject typed at the boundary" do
    get report_path, headers: bearer(@admin),
      params: { from: "2026-08-21T10:30:00Z", to: "2026-08-21T11:00:00Z" }
    assert_response :bad_request
    assert_equal "window_invalid", response.parsed_body.dig("error", "code")

    get report_path, headers: bearer(@admin),
      params: { from: "yesterday", to: "2026-08-21T11:00:00Z" }
    assert_response :bad_request

    get report_path, headers: bearer(@admin), params: { to: "2026-08-21T11:00:00Z" }
    assert_response :bad_request, "a missing edge is a missing parameter"
  end

  test "unknown filter keys and non-scalar values refuse instead of widening" do
    window = { from: "2026-08-21T10:00:00Z", to: "2026-08-21T11:00:00Z" }

    get report_path, headers: bearer(@admin), params: window.merge(provider: "dev")
    assert_response :bad_request
    assert_equal "filter_unsupported", response.parsed_body.dig("error", "code"),
      "a misspelled dimension must never silently answer account-wide"

    get report_path, headers: bearer(@admin),
      params: window.merge(status: %w[succeeded failed])
    assert_response :bad_request
    assert_equal "filter_invalid", response.parsed_body.dig("error", "code"),
      "an array value must never silently drop the filter"
  end

  test "a member credential is not an administrator" do
    get report_path, headers: bearer(@member_token),
      params: { from: "2026-08-21T10:00:00Z", to: "2026-08-21T11:00:00Z" }
    assert_response :unauthorized
  end

  private

    def report_path = "/api/v1/admin/model_usage/report"

    def bearer(fixture)
      { "Authorization" => "Bearer #{fixture.secret}" }
    end
end
