require "test_helper"

class Admin::ModelUsageReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @window = { from: "2026-10-10T00:00:00Z", to: "2026-10-12T00:00:00Z", unit: "day" }
    UsageRecord.create!(account: accounts(:cybros), idempotency_key: "html-usage",
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      consumer_user_public_id: users(:member).public_id,
      provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text",
      workload: "text_generation", purpose: "task", service_class: "interactive",
      admission_shape: "priced", status: "succeeded", recorded_at: Time.utc(2026, 10, 11),
      total_tokens: 123, cost_amount: nil)
  end

  test "administrators see a fixed aggregate summary and a separate export form" do
    travel_to Time.utc(2026, 10, 12, 12) do
      get admin_model_usage_path, params: @window.merge(provider_id: "missing")
      assert_response :success
      assert_select "article[aria-label='Model requests']", text: /1/
      assert_select "article[aria-label='Tokens']", text: /123/
      assert_select "article[aria-label='Recorded cost']", text: /Not available/
      assert_select "table", count: 0
      assert_not_includes response.body, users(:member).public_id
      assert_select "input[name='consumer_user_public_id']", 0
      assert_select "form[action=?]", admin_model_usage_path, count: 0
      assert_select "form[action=?]", admin_model_usage_export_path
    end
  end

  test "download refuses member dimensions and malformed dates" do
    %w[consumer_user_public_id payer_user_public_id workspace_public_id billing_subject_key].each do |key|
      get admin_model_usage_export_path, params: @window.except(:unit).merge(key => "member")
      assert_response :bad_request
    end
    get admin_model_usage_export_path, params: @window.except(:unit).merge(from: "yesterday")
    assert_response :bad_request
  end

  test "ordinary Humans cannot enter Account reporting" do
    sign_out
    sign_in_as users(:member)
    get admin_model_usage_path, params: @window
    assert_response :forbidden
  end
end
