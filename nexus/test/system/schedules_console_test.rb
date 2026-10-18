require "application_system_test_case"
require_relative "../test_helpers/schedules_console_test_helper"

class SchedulesConsoleJourneyTest < ApplicationSystemTestCase
  include SchedulesConsoleTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @conversation = schedule_conversation(title: "Scheduled inbox")
    @job = console_schedule
  end

  test "a human filters schedules, changes the clock and follows its exact waiting input" do
    sign_in_directly(@human)
    visit workspace_schedules_path(@workspace)
    previous_body = find("body", visible: :all).native
    click_button "Apply filters"
    assert_selector("body", visible: :all) { |body| body.native != previous_body }
    click_link "Inbox review", exact: true
    assert_text "Saved instructions"
    assert_text "Review the inbox"
    click_button "Pause schedule"
    assert_button "Resume schedule"
    click_button "Run now"
    assert_text "Schedule command accepted."
    assert_button "Resume schedule"
    child = @job.reload.last_execution_conversation
    assert_equal @human, child.creating_user
    assert_nil @job.next_run_at
    detail = URI.parse(page.current_url).request_uri
    click_link "View waiting input"
    assert_selector "[data-input-id='#{child.scheduled_input_public_id}']"
    within("main nav") { click_link }
    assert_current_path detail
    click_link "Execution history"
    assert_selector "[data-execution-id='#{child.public_id}']"
    page.save_screenshot(Rails.root.join("tmp/screenshots/schedules-history-desktop.png"))
    within("main nav") { click_link }
    click_button "Resume schedule"
    assert_button "Pause schedule"
    confirm_through_dialog { click_button "Cancel schedule" }
    assert_text "Canceled"
    assert_no_button "Run now"
    assert_empty child.inputs
  end
end

class MobileSchedulesConsoleJourneyTest < MobileSystemTestCase
  include SchedulesConsoleTestHelper

  test "a narrow schedule page keeps its controls and history reachable" do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = schedule_conversation
    job = console_schedule(name: "A schedule with a long readable title across a narrow viewport")
    sign_in_directly(@human)
    visit workspace_schedules_path(@workspace)
    click_link job.name
    assert_button "Pause schedule"
    assert_viewport_contains_page
    click_button "Pause schedule"
    assert_button "Resume schedule"
    find("summary", text: "Saved execution configuration").click
    assert_text "mock-text"
    assert_viewport_contains_page
    page.save_screenshot(Rails.root.join("tmp/screenshots/schedules-detail-mobile.png"))
    click_link "Execution history"
    assert_text "No executions are available to view."
    assert_viewport_contains_page
    within("main nav") { click_link }
    assert_button "Resume schedule"
  end

  private

    def assert_viewport_contains_page
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end
