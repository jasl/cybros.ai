require "application_system_test_case"

class MembershipLifecycleJourneyTest < ApplicationSystemTestCase
  setup do
    @owner = users(:owner)
    @member = users(:member)
  end

  test "a removed Agent is reassigned while its old credentials remain unusable" do
    connected = connect_agent_session(
      steward: @owner,
      agent_identifier: "removed-handoff",
      display_name: "Removed handoff",
      device_name: "Old device"
    )
    agent = connected.access_token.user
    address = connected.executor_access_token.executor

    sign_in_directly(@owner)
    visit admin_agent_url(agent.public_id)

    confirm_through_dialog { click_button "Remove Agent" }
    assert_text I18n.t("admin.agents.removed")
    assert_not_predicate connected.access_token.reload, :usable?
    assert_not_predicate connected.executor_access_token.reload, :usable?
    click_link "Change manager"

    fill_in "Search users", with: @member.email
    click_button "Search"
    assert_text "Showing 1–1 of 1 eligible user"
    within("[data-steward-candidate-id='#{@member.public_id}']") { click_button "Assign" }

    assert_text "Manager updated"
    assert_predicate agent.reload, :removed?
    assert_equal @member, agent.steward
    assert_predicate address.reload, :active?
  end
end
