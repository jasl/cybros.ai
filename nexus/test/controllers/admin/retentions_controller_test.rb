require "test_helper"

class Admin::RetentionsControllerTest < ActionDispatch::IntegrationTest
  test "the administrator form shares the Account setting and preserves failed input" do
    sign_in_as users(:owner)
    get admin_retention_path
    assert_response :success
    assert_select "h1", "Retention settings"
    assert_select "input[name=?][value=?]", "account[execution_details_retention_days]", "90"

    patch admin_retention_path, params: { account: { execution_details_retention_days: "120" } }
    assert_redirected_to admin_retention_path
    assert_equal 120, accounts(:cybros).reload.execution_details_retention_days

    patch admin_retention_path, params: { account: { execution_details_retention_days: "-2" } }
    assert_response :unprocessable_entity
    assert_select "input[name=?][value=?]", "account[execution_details_retention_days]", "-2"
    assert_select "[role=alert]"
    assert_equal 120, accounts(:cybros).reload.execution_details_retention_days

    patch admin_retention_path, params: { account: { execution_details_retention_days: "" } }
    assert_redirected_to admin_retention_path
    assert_nil accounts(:cybros).reload.execution_details_retention_days
  end

  test "ordinary members cannot read or change retention" do
    sign_in_as users(:member)
    get admin_retention_path
    assert_response :forbidden
    patch admin_retention_path, params: { account: { execution_details_retention_days: "" } }
    assert_response :forbidden
    assert_equal 90, accounts(:cybros).reload.execution_details_retention_days
  end
end
