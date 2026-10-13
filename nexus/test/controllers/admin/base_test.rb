require "test_helper"

class AdminBaseTest < ActionDispatch::IntegrationTest
  test "admin pages render the administration navigation and a route back to the console" do
    sign_in_as users(:owner)

    get admin_users_path

    assert_response :success
    assert_select "aside" do
      assert_select "a[href=?]", root_path, text: "Back to console"
      assert_select "a[href=?]", admin_users_path, text: "Members"
      assert_select "a[href=?]", admin_invitations_path, text: "Invitations"
      assert_select "a[href=?]", root_path, text: "Dashboard", count: 0
    end
  end

  test "admin pages deny ordinary members with an honest 403" do
    sign_in_as users(:member)

    get admin_users_path
    assert_response :forbidden

    get admin_invitations_path
    assert_response :forbidden
  end

  test "admin pages require authentication" do
    get admin_users_path
    assert_redirected_to new_session_path(return_to: admin_users_path)
  end
end
