require "application_system_test_case"

class RunnerConnectionJourneyTest < ApplicationSystemTestCase
  test "an administrator submits account-wide Runner availability from the confirmation form" do
    grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), runner_identifier: "farm-install",
      runner_display_name: "Workshop laptop"
    ).authorization
    sign_in_directly(users(:owner))

    visit oauth_device_url(user_code: grant.formatted_user_code)
    click_button "Continue"

    assert_text "Connect runner"
    assert_no_text "Connect agent program"
    assert_text grant.formatted_user_code
    assert_no_text "farm-install"
    assert_no_text "Workshop laptop"
    assert_no_selector "select"
    assert_no_selector "input[type='radio']"
    assert_unchecked_field "Make this runner available account-wide"

    check "Make this runner available account-wide"
    click_button "Connect"

    assert_text "This Runner will be available account-wide"
    assert_predicate grant.reload, :selects_account_wide?
  end

  # The provider's page is the runner's with its own word: the scope block is identical because a
  # provider's admission IS the runner's ACL.
  test "a tools-provider connection names its kind and takes the runner's scope block" do
    grant = DeviceAuthorizations::Issue.call(
      account: accounts(:cybros), runner_identifier: "provider-install",
      runner_display_name: "Provider box", requested_executor_kind: "tools_provider"
    ).authorization
    sign_in_directly(users(:owner))

    visit oauth_device_url(user_code: grant.formatted_user_code)
    click_button "Continue"

    assert_text "Connect tools provider"
    assert_no_text "Connect runner"
    assert_text "Tools provider"
    assert_no_text "provider-install"
    assert_unchecked_field "Make this tools provider available account-wide"

    check "Make this tools provider available account-wide"
    click_button "Connect"

    assert_text "This Tools provider will be available account-wide"
    assert_predicate grant.reload, :selects_account_wide?
  end
end
