require "test_helper"

class Admin::ModelUsageExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:owner)
    @window = { from: "2026-10-10T00:00:00Z", to: "2026-10-12T00:00:00Z" }
  end

  test "the retired interactive HTML analysis has no route while the API remains" do
    get "/admin/model_usage/analysis"
    assert_response :not_found
    get admin_model_usage_export_path, params: @window.merge(workspace_public_id: workspaces(:shared).public_id)
    assert_response :bad_request
  end

  test "non-admin Humans cannot enter aggregate analysis" do
    sign_out
    sign_in_as users(:member)
    get admin_model_usage_export_path, params: @window
    assert_response :forbidden
  end

  test "structured grouping values cannot render a default Account report" do
    { group_by: ["status"], rank_by: { value: "cost_amount" }, limit: ["0"] }.each do |field, value|
      get admin_model_usage_export_path, params: @window.merge(field => value)
      assert_response :bad_request
    end
  end
end
