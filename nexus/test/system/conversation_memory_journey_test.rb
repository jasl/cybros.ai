require "application_system_test_case"

class ConversationMemoryJourneyTest < ApplicationSystemTestCase
  test "conversation shows current and captured bindings consistently at desktop and mobile widths" do
    human = users(:member)
    workspace = workspaces(:shared)
    collection = MemoryCollection.default_for(workspace)
    conversation = Conversation.create!(workspace: workspace, creating_user: human, answering_user: users(:agent), title: "Project memory",
      memory_context: { "bindings" => [{ "name" => "project", "source" => { "collection_public_id" => collection.public_id }, "access" => "read_write" }] })
    create_run_backed_turn(conversation: conversation, acting_user: human)
    conversation.update!(memory_context: { "bindings" => [] })
    collection.archive
    sign_in_directly(human)
    [1400, 390].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: 1000, deviceScaleFactor: 1, mobile: width == 390)
      visit conversation_url(conversation)
      assert_selector "summary", text: "Memory bindings"
      within("section[aria-label='Current selection']") { assert_text "No available memory bindings." }
      within("section[aria-label='Active execution']") do
        assert_text "project/"
        assert_text "Read only"
        assert_text "Archived"
        assert_link "Default collection", href: memory_collection_path(collection)
      end
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "conversation must fit viewport"
      page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-memory-#{width}.png"))
      within("section[aria-label='Active execution']") { click_link "Default collection" }
      assert_selector "h1", text: "Default collection"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
