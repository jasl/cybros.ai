require "test_helper"

class UsageReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:member)
    @window = { from: "2026-10-10T12:15:30.123456Z", to: "2026-10-12T12:15:30.654321Z" }
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member), answering_user: users(:agent))
    UsageRecord.create!(account: accounts(:cybros), idempotency_key: SecureRandom.uuid_v7,
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      conversation_public_id: @conversation.public_id, consumer_user_public_id: users(:member).public_id,
      provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text", workload: "text_generation",
      purpose: "task", service_class: "interactive", admission_shape: "priced", status: "succeeded",
      recorded_at: Time.utc(2026, 10, 11), duration_ms: 0, total_tokens: 12)
  end

  test "the fixed summary ignores analysis queries and offers scoped evidence download" do
    travel_to Time.utc(2026, 10, 12, 12, 15, 30) do
      get usage_path, params: @window.merge(workspace_public_id: workspaces(:shared).public_id, provider_id: "missing")
      assert_response :success
      assert_select "h1", text: "Work usage"
      assert_select "article[aria-label='Model requests']", text: /1/
      assert_select "article[aria-label='Recorded cost']", text: /Not available/
      assert_select "form[action=?]", usage_path, count: 0
      assert_select "form[action=?]", usage_export_path do
        assert_select "input[name='workspace_public_id'][value=?]", workspaces(:shared).public_id
        assert_select "input[name='from'][value='2026-10-05T12:15:30.000000Z']"
        assert_select "input[type='datetime-local'][id='from_datetime'][value='2026-10-05T12:15:30'][step='1']"
        assert_select "input[name='to'][value='2026-10-12T12:15:30.000000Z']"
      end
      assert_select "table", count: 0
    end
  end

  test "exports preserve exact bounds and refuse wide windows or malformed selectors" do
    get usage_export_path, params: @window.merge(to: "2027-01-15T12:15:30Z")
    assert_response :bad_request
    get usage_path, params: { workspace_public_id: workspaces(:personal).public_id }
    assert_response :not_found
    { group_by: ["status"], rank_by: { value: "cost_amount" }, limit: ["0"] }.each do |field, value|
      get usage_export_path, params: @window.merge(field => value)
      assert_response :bad_request
    end
  end
end
