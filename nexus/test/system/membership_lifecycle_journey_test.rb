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
    address = connected.executor_access_token.task_executor

    sign_in_directly(@owner)
    visit admin_user_url(agent.public_id)

    confirm_through_dialog { click_button "Remove" }
    assert_text I18n.t("admin.users.agent_removed")
    assert_not_predicate connected.access_token.reload, :usable?
    assert_not_predicate connected.executor_access_token.reload, :usable?
    click_link "Reassign steward"

    fill_in "Search members", with: @member.email
    click_button "Search"
    assert_text "Showing 1–1 of 1 eligible members"
    within("[data-steward-candidate-id='#{@member.public_id}']") { click_button "Assign" }

    assert_text "Steward updated"
    assert_predicate agent.reload, :removed?
    assert_equal @member, agent.steward
    assert_predicate address.reload, :active?
  end
end
