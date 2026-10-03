require "application_system_test_case"

class AccessTokenJourneyTest < ApplicationSystemTestCase
  test "a member mints a token and sees it once" do
    sign_in_directly(users(:member))
    visit settings_tokens_url

    assert_field "Current password", type: "password", with: ""
    fill_in "Name", with: "CI runner"
    fill_in "Current password", with: "password"
    click_button "Create token"

    assert_text "you won't be able to see it again"
    secret = find("input[aria-label='New access token']").value
    assert secret.start_with?("sk-cybros-api-v1-")

    click_link "Done"
    assert_text "CI runner"
    assert_no_text "sk-cybros-api-v1-"
  end
end
