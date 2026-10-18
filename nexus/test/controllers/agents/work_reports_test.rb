require "test_helper"

class Agents::WorkReportsTest < ActionDispatch::IntegrationTest
  setup do
    @agent = users(:agent)
    sign_in_as users(:owner)
  end

  test "the Agent summary has one fixed window and a consumer-scoped export" do
    get agent_work_report_path(@agent), params: { from: "not a date", to: "2026-10-16T00:00:00Z" }
    assert_response :success
    assert_select "form[action=?]", agent_work_report_path(@agent), count: 0
    assert_select "form[action=?]", usage_export_path do
      assert_select "input[name='agent_public_id'][value=?]", @agent.public_id
    end
    assert_includes response.body, I18n.t("resource_work.usage_coverage")
    assert_select "table", count: 0
  end

  test "the management entry stays steward scoped even when other people can read related work" do
    sign_out
    sign_in_as users(:member)
    get agent_work_report_path(@agent)
    assert_response :not_found
  end
end
