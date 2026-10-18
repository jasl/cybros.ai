require "application_system_test_case"

module ConversationSearchJourney
  extend ActiveSupport::Concern

  included do
    test "search filters lead to the exact retained field and continue back to the original results" do
      human = users(:owner)
      answerer = users(:agent)
      workspace = workspaces(:shared)
      conversation = Conversation.create!(workspace: workspace, creating_user: human,
        answering_user: answerer, title: "Window review")
      turn = conversation.turns.create!(position: 0, kind: "message", role: "user", status: "completed",
        speaker: Speakers::Resolve.member(account: conversation.account, user: human), control_owner_user: human)
      variant = turn.variants.create!(position: 0, status: "completed", source: "manual")
      turn.update!(active_variant: variant)
      entries = Array.new(24) { { "text" => "Earlier accepted note" } }
      field_text = "前言🙂" * 10_000 + " needle original " + "續" * 8_000 +
        " END OF FIELD <script>window.searchExecuted = true</script>"
      entries << { "parts" => [{ "type" => "text", "text" => "First part" },
        { "type" => "text", "text" => field_text }] }
      ContentBodies::Replace.archive(owner: variant, role: "steers", entries: entries)
      conversation.update!(timeline_position_head: 1, archived_at: Time.current)
      title_match = Conversation.create!(workspace: workspace, creating_user: human,
        answering_user: answerer, title: "needle title match", archived_at: Time.current)
      Conversation.create!(workspace: workspace, creating_user: human,
        title: "needle other answerer", archived_at: Time.current)
      Conversation.create!(workspace: workspaces(:dedicated), creating_user: human,
        answering_user: answerer, title: "needle other workspace", archived_at: Time.current)

      visit new_session_url
      fill_in "Email", with: human.email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Overview"
      visit workspace_conversations_path(workspace)
      assert_selector "main h1", text: I18n.t("conversation_console.conversations"), exact_text: true
      select I18n.t("conversation_console.archive_options.only"), from: I18n.t("conversation_console.archive_filter")
      select answerer.display_name, from: "Default answerer"
      fill_in I18n.t("conversation_console.search"), with: "needle"
      click_button I18n.t("conversation_console.filter")
      assert_link "Window review"
      assert_link title_match.title
      assert_no_link "needle other answerer"
      assert_no_link "needle other workspace"
      results_path = URI.parse(page.current_url).request_uri
      assert_page_fits_viewport
      page.save_screenshot(Rails.root.join("tmp/screenshots/search-results-#{self.class.name.underscore}.png"))

      replacement = turn.variants.create!(position: 1, status: "completed", source: "manual")
      ContentBodies::Replace.call(owner: replacement, role: "content", entries: [{ "text" => "needle replacement" }], seal: true)
      turn.update!(active_variant: replacement)
      variant.update!(details_pruned_at: Time.current)
      find_link("Window review").send_keys(:enter)
      assert_current_path conversation_turn_variant_field_path(conversation, turn.public_id, variant.public_id, "steers"), ignore_query: true
      assert_selector "article[data-history-field='steers']", text: "needle original"
      assert_no_text "needle replacement"
      assert_no_text "END OF FIELD"
      assert_text variant.public_id
      assert_link "View context"
      assert_no_link "Open execution"
      first_window = find("article p").evaluate_script("this.textContent")
      assert_operator first_window.bytesize, :<=, 16 * 1_024
      assert_page_fits_viewport
      page.scroll_to(:top)
      page.save_screenshot(Rails.root.join("tmp/screenshots/search-field-#{self.class.name.underscore}.png"))
      click_link "Continue reading"
      assert_current_path conversation_turn_variant_field_path(conversation, turn.public_id, variant.public_id, "steers"), ignore_query: true
      assert_text "END OF FIELD"
      assert_no_text "needle original"
      assert_no_link "Continue reading"
      next_window = find("article p").evaluate_script("this.textContent")
      assert_operator next_window.bytesize, :<=, 16 * 1_024
      assert field_text.end_with?(first_window + next_window), "The windows must preserve the complete original text after the search location"
      assert_no_selector "article script", visible: :all
      assert page.evaluate_script("window.searchExecuted === undefined")
      assert_page_fits_viewport
      page.scroll_to(:bottom)
      page.save_screenshot(Rails.root.join("tmp/screenshots/search-continuation-#{self.class.name.underscore}.png"))
      click_link "Back to results"
      assert_current_path results_path
      assert_selector "main summary", text: "#{workspace.name} · Switch Workspace"
      assert_no_select I18n.t("conversation_console.workspace")
      assert_select I18n.t("conversation_console.archive_filter"), selected: I18n.t("conversation_console.archive_options.only")
      assert_select "Default answerer", selected: answerer.display_name
      assert_field I18n.t("conversation_console.search"), with: "needle"
      assert_link "Window review"
      click_link title_match.title
      assert_current_path conversation_path(title_match, return_to: results_path)
      assert_selector "main h1", text: title_match.title, exact_text: true
      assert_no_selector "article[data-history-field]"
      within("main nav[aria-label='Back']") { click_link I18n.t("shared.back_navigation.back"), exact: true }
      assert_current_path results_path
    end
  end

  private

    def assert_page_fits_viewport
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end

class ConversationSearchJourneyTest < ApplicationSystemTestCase
  include ConversationSearchJourney
end

class MobileConversationSearchJourneyTest < MobileSystemTestCase
  include ConversationSearchJourney
end
