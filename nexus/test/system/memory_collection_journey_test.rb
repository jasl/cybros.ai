require "application_system_test_case"

class MemoryCollectionJourneyTest < ApplicationSystemTestCase
  test "collection and document management stays usable on desktop and narrow screens" do
    sign_in_directly(users(:owner))
    run_memory_journey("desktop")
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    run_memory_journey("mobile")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

    def run_memory_journey(viewport)
      visit memory_collections_url
      assert_selector "h1", text: "Memory collections"
      click_link "New collection"
      assert_text "Create a collection owned by"
      fill_in "Name", with: "Research #{viewport}"
      fill_in "Description", with: "Notes for upcoming research and decisions."
      click_button "Save collection"
      assert_text "Collection saved."
      assert_selector "h1", text: "Research #{viewport}"
      capture_memory_layout("#{viewport}-overview")
      click_link "Documents", exact: true
      assert_text "No documents in this collection."
      click_link "New memory document"
      fill_in "Document path", with: "research/project-notes.md"
      fill_in "Memory content", with: "A durable research note."
      click_button "Save memory document"
      assert_text "Memory document saved."
      click_link "Edit", exact: true
      fill_in "Memory content", with: "Updated research note."
      click_button "Save memory document"
      assert_text "Updated research note."
      click_link "Research #{viewport}", exact: true
      capture_memory_layout("#{viewport}-documents")
      within("nav[aria-label='Collection pages']") { click_link "Overview", exact: true }
      click_button "Archive collection"
      assert_text "Collection archived."
      click_link "Documents", exact: true
      assert_text "This collection is read only."
      assert_no_link "New memory document"
      click_link "Memory collections", exact: true, match: :first
      fill_in "Search collections", with: "Research #{viewport}"
      click_button "Filter"
      assert_text "No readable collections."
      select "Archived", from: "Status"
      click_button "Filter"
      assert_link "Research #{viewport}"
      capture_memory_layout("#{viewport}-inventory")
      click_link "Research #{viewport}", exact: true
      click_button "Restore collection"
      assert_text "Collection restored."
    end

    def capture_memory_layout(name)
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "page must fit viewport"
      page.save_screenshot(Rails.root.join("tmp/screenshots/memory-#{name}.png"))
    end
end
