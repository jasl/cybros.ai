require "application_system_test_case"

module WorkspaceDataJourney
  extend ActiveSupport::Concern

  included do
    test "a shared workspace member maintains Memory character and opaque Store values" do
      workspace = workspaces(:shared)
      collection = MemoryCollection.default_for(workspace)
      sign_in_directly(users(:member))
      visit workspace_data_url(workspace)
      find_link("Memory collections", href: memory_collections_path(workspace_public_id: workspace.public_id), exact_text: true).send_keys(:enter)
      assert_current_path memory_collections_path(workspace_public_id: workspace.public_id)
      find_link(href: memory_collection_path(collection)).click
      click_link "Documents", exact: true
      assert_current_path memory_collection_documents_path(collection)
      click_link "New memory document"
      fill_in "Document path", with: "notes.md"
      fill_in "Memory content", with: "First note"
      click_button "Save memory document"
      assert_text "Memory document saved."
      click_link "Edit", exact: true
      fill_in "Memory content", with: "My unsaved draft"
      anchor = memory_anchor(path: "workspace/notes.md", workspace: workspace)
      workspace.with_lock { MemoryDocuments::Write.call(anchor: anchor, content: "Another edit", expected: nil) }
      click_button "Save memory document"
      assert_text "Your draft and its original version are kept"
      assert_field "Memory content", with: "My unsaved draft"
      assert_link "Read the saved value", target: "_blank"
      assert_data_viewport

      visit memory_collection_document_url(collection, path: "notes.md")
      assert_text "Another edit"
      confirm_through_dialog { click_button "Delete", exact: true }
      assert_text "Memory document deleted."
      assert_text "No documents in this collection."

      visit workspace_character_url(workspace)
      click_link "Edit character"
      select "Developer", from: "Prompt role"
      fill_in "Character content", with: "{{unknown_macro}}"
      click_button "Save character"
      assert_text "Unknown macro: unknown_macro"
      assert_field "Character content", with: "{{unknown_macro}}"
      assert_select "Prompt role", selected: "Developer"
      fill_in "Character content", with: ""
      click_button "Save character"
      assert_text "Character saved."
      assert_button "Delete character"
      confirm_through_dialog { click_button "Delete character" }
      assert_text "This workspace has no character document."

      visit workspace_store_entries_url(workspace)
      click_link "New Store entry"
      assert_current_path new_workspace_store_entry_path(workspace)
      # The list also has a Namespace filter; wait for the creation field so a
      # Turbo visit cannot accept the first fill on the page being replaced.
      fill_in "store_entry_namespace", with: "application.state"
      fill_in "Key", with: "long-#{"key" * 50}"
      fill_in "JSON value", with: "{ broken"
      click_button "Save Store entry"
      assert_text "Enter valid JSON."
      assert_field "JSON value", with: "{ broken"
      fill_in "JSON value", with: '[false,null,{"nested":[1,"text"]}]'
      click_button "Save Store entry"
      assert_text "Store entry saved."
      assert_text '"nested"'
      assert_data_viewport
      click_link "Edit", exact: true
      fill_in "JSON value", with: "null"
      click_button "Save Store entry"
      assert_selector "pre", text: "null"
      confirm_through_dialog { click_button "Delete", exact: true }
      assert_text "Store entry deleted."

      visit workspace_data_url(workspace)
      click_link "Browse Conversations"
      assert_current_path workspace_conversations_path(workspace)
      page.go_back
      assert_current_path workspace_data_path(workspace)
      click_link "Browse Runs"
      assert_current_path workspace_runs_path(workspace)
      assert_data_viewport
    end
  end

  private

    def assert_data_viewport
      width = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
    end
end

class WorkspaceDataJourneyTest < ApplicationSystemTestCase
  include WorkspaceDataJourney
end

class MobileWorkspaceDataJourneyTest < MobileSystemTestCase
  include WorkspaceDataJourney
end
