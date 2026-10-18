require "application_system_test_case"
require "net/http"
require "zlib"
require_relative "../test_helpers/runs_result_delivery_test_helper"

class WorkConsoleJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include RunsResultDeliveryTestHelper

  test "a human follows application work through a question, result and diagnostic download" do
    @conversation.update!(title: "Quarterly review")
    _turn, run = open_turn!("Review the draft")
    call_round!(run, "r1", "ask", { prompt: "Which version should I review?" })
    question = run.tasks.where(type: Tasks::AwaitTask.sti_name).sole
    assert_equal "awaiting_input", question.status

    sign_in_directly(@human)
    visit root_url
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-dashboard-desktop.png"))
    within("section[aria-labelledby='recent-work-heading']") { click_link "Quarterly review" }
    assert_current_path conversation_path(@conversation, return_to: "/")
    assert_text "Review the draft"
    within("main") { click_link "Current execution" }
    assert_text run.public_id
    within("main nav", text: "Transcript") { click_link "Graph", exact: true }
    assert_selector "svg[aria-labelledby='run-graph-title'] a", count: run.tasks.count
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-graph-desktop.png"))
    within("main nav", text: "Transcript") { click_link "Tasks", exact: true }
    # The graph already links this Task; scope the click to the loaded list.
    assert_current_path run_tasks_path(run), ignore_query: true
    within("table") { click_link question.node_key, exact: true }
    assert_current_path run_task_path(run, question.node_key), ignore_query: true
    assert_text "Which version should I review?"
    assert_text "Live updates connected"
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-task-desktop.png"))
    fill_in "Your answer", with: "Version blue"
    click_button "Send answer"
    assert_text "Command accepted"
    assert_no_field "Your answer"
    assert_equal "completed", question.reload.status
    assert_equal "Version blue", question.content_bodies.find_by!(role: "output").effective_text

    schedule_loop!(run)
    run_round!(run, "r2", "Version blue is ready for review.")
    converge!
    within("main nav", text: "Transcript") { click_link "Conversation", exact: true }
    assert_text "Version blue is ready for review."
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-conversation-desktop.png"))
    download = find_link("Download diagnostics")
    response = download_with_browser_session(download[:href])
    assert_equal "200", response.code
    assert_equal "application/gzip", response.content_type
    assert_includes response["content-disposition"], @conversation.public_id
    lines = Zlib::GzipReader.new(StringIO.new(response.body)).each_line.map { |line| JSON.parse(line) }
    assert lines.any? { |line| line.to_json.include?(run.public_id) }
    assert lines.any? { |line| line.to_json.include?("Version blue is ready for review.") }
  end

  private

    def download_with_browser_session(href)
      uri = URI.join(page.current_url, href)
      request = Net::HTTP::Get.new(uri)
      request["Cookie"] = page.driver.browser.manage.all_cookies.map { |cookie| "#{cookie.fetch(:name)}=#{cookie.fetch(:value)}" }.join("; ")
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    end
end

class MobileWorkConsoleJourneyTest < MobileSystemTestCase
  include ActiveJob::TestHelper
  include RunsResultDeliveryTestHelper

  test "narrow work navigation keeps a standalone task and its controls reachable" do
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    start = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    assert_predicate start, :accepted?
    schedule_loop!(run)
    call_round!(run, "round1", "ask", { prompt: "Confirm the standalone check" })
    question = run.tasks.where(type: Tasks::AwaitTask.sti_name).sole

    sign_in_directly(@human)
    visit root_url
    assert_text "Overview"
    assert_viewport_contains_page
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-dashboard-mobile.png"))
    open_mobile_sidebar
    within("aside") { click_link "Needs attention", exact: true }
    assert_current_path attention_path
    within("article[data-run-id='#{run.public_id}']") { click_link "Open task" }
    assert_text "Confirm the standalone check"
    assert_text "Live updates connected"
    assert_no_link "Conversation", exact: true
    assert_link "Download diagnostics", href: run_export_path(run)
    assert_viewport_contains_page
    page.save_screenshot(Rails.root.join("tmp/screenshots/work-console-task-mobile.png"))
    fill_in "Your answer", with: "Proceed"
    click_button "Send answer"
    assert_text "Command accepted"
    assert_equal "completed", question.reload.status
    click_button "Pause", exact: true
    assert_button "Resume", exact: true
    click_button "Resume", exact: true
    assert_button "Pause", exact: true
    confirm_through_dialog { click_button "Stop", exact: true }
    assert_no_button "Pause", exact: true
    assert_predicate run.reload, :stopped?
    assert_viewport_contains_page
    within("main") { click_link "Back to work" }
    assert_current_path attention_path
    assert_no_selector "article[data-run-id='#{run.public_id}']"
  end

  private

    def assert_viewport_contains_page
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end
