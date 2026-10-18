require "application_system_test_case"
require "net/http"
require "zlib"

class UsageReportJourneyTest < ApplicationSystemTestCase
  test "a Human reads a fixed summary and downloads the selected receipt evidence" do
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human, answering_user: users(:agent))
    UsageRecord.create!(account: accounts(:cybros), idempotency_key: SecureRandom.uuid_v7,
      model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
      conversation_public_id: conversation.public_id, consumer_user_public_id: human.public_id,
      provider_id: "browser-provider", catalog_model_ref: "browser-provider/text", wire_model_id: "text", workload: "text_generation",
      purpose: "task", service_class: "interactive", admission_shape: "priced", status: "succeeded",
      recorded_at: 1.hour.ago, total_tokens: 12, duration_ms: 0)
    sign_in_directly(human)
    visit usage_path(workspace_public_id: workspaces(:shared).public_id)
    assert_text "Work usage"
    assert_text "Not available"
    assert_selector "article[aria-label='Model requests']", text: "1"
    find("summary", text: "Export usage").click
    assert_predicate find_field("From (UTC)").value, :present?
    assert_predicate find_field("To (UTC)").value, :present?
    fill_in "Provider", with: "browser-provider"
    select "Recorded cost", from: "Sort by"
    assert_selector "article[aria-label='Model requests']", text: "1"
    form = find("form[action='#{usage_export_path}']")
    fields = form.all("input[name], select[name]", visible: :all).to_h { |field| [field[:name], field.value] }
    uri = URI.join(page.current_url, "#{form[:action]}?#{URI.encode_www_form(fields)}")
    request = Net::HTTP::Get.new(uri)
    request["Cookie"] = page.driver.browser.manage.all_cookies.map { |cookie| "#{cookie.fetch(:name)}=#{cookie.fetch(:value)}" }.join("; ")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
    assert_equal "200", response.code
    records = Zlib::GzipReader.wrap(StringIO.new(response.body), &:read).lines.map { |line| JSON.parse(line) }
    assert_equal "end", records.last.fetch("type")
    assert_equal "browser-provider", records.first.dig("filters", "provider_id")
    assert_equal conversation.public_id, records.find { |record| record["type"] == "usage" }.dig("usage", "conversation_public_id")
    assert_no_selector "table"
    page.save_screenshot(Rails.root.join("tmp/screenshots/usage-report-desktop.png"))
  end
end

class MobileUsageReportJourneyTest < MobileSystemTestCase
  test "the fixed summary and file options fit a narrow viewport" do
    sign_in_directly(users(:member))
    page.current_window.resize_to(390, 844)
    visit usage_path
    assert_text "Work usage"
    assert_text "Last 7 days"
    find("summary", text: "Export usage").click
    select "Model", from: "Group by"
    fill_in "Top groups (1–50)", with: "5"
    assert_button "Download report"
    assert_no_button "Apply"
    assert_no_selector "table"
    viewport = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    page.save_screenshot(Rails.root.join("tmp/screenshots/usage-report-mobile.png"))
  end
end
