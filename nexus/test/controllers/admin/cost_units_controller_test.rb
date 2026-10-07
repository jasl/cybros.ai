require "test_helper"

class Admin::CostUnitsControllerTest < ActionDispatch::IntegrationTest
  test "cost unit form configures once and renders invalid and conflicting submissions" do
    account = accounts(:cybros)
    sign_in_as users(:owner)
    get admin_cost_unit_path
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"

    patch admin_cost_unit_path, params: { account: { cost_unit: " " } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]"
    assert_nil account.reload.cost_unit
    invalid = "x" * (Account::COST_UNIT_MAX_LENGTH + 1)
    patch admin_cost_unit_path, params: { account: { cost_unit: invalid } }
    assert_response :unprocessable_entity
    assert_select "input[name=?][value=?]", "account[cost_unit]", invalid
    assert_nil account.reload.cost_unit
    patch admin_cost_unit_path, params: { account: { cost_unit: " USD " } }
    assert_redirected_to admin_cost_unit_path
    assert_response :see_other
    assert_equal "USD", account.reload.cost_unit
    patch admin_cost_unit_path, params: { account: { cost_unit: "USD" } }
    assert_redirected_to admin_cost_unit_path
    patch admin_cost_unit_path, params: { account: { cost_unit: "EUR" } }
    assert_response :conflict
    assert_select "[role=alert]"
    assert_equal "USD", account.reload.cost_unit
  end

  test "ordinary members cannot read or configure the account cost unit" do
    sign_in_as users(:member)
    get admin_cost_unit_path
    assert_response :forbidden
    patch admin_cost_unit_path, params: { account: { cost_unit: "USD" } }
    assert_response :forbidden
    assert_nil accounts(:cybros).reload.cost_unit
  end
end
