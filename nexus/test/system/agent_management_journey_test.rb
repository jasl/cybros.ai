require "application_system_test_case"

class MobileAgentManagementJourneyTest < MobileSystemTestCase
  test "the registration card stays readable on a narrow viewport" do
    owner = users(:owner)
    result = connect_agent_session(
      steward: owner, agent_identifier: "i" * User::AGENT_IDENTIFIER_MAX_LENGTH,
      display_name: "L" * User::DISPLAY_NAME_MAX_LENGTH,
      device_name: "D" * TaskExecutor::DISPLAY_NAME_MAX_LENGTH
    )
    sign_in_directly(owner)

    visit agent_url(result.access_token.user.public_id)

    assert_button "Revoke credentials"
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    # Long names wrap inside the card; the page itself never scrolls sideways,
    # and no control is pushed out of reach.
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"),
      :<=, viewport_width + 1, "the page must not scroll horizontally"
    bounds = page.evaluate_script(<<~JAVASCRIPT, find_button("Revoke credentials"))
      (() => {
        const rect = arguments[0].getBoundingClientRect()
        return { left: rect.left, right: rect.right }
      })()
    JAVASCRIPT
    assert_operator bounds.fetch("left"), :>=, 0
    assert_operator bounds.fetch("right"), :<=, viewport_width
  end
end
