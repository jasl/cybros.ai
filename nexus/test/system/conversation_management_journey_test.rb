require "application_system_test_case"

module ConversationManagementJourney
  extend ActiveSupport::Concern

  included do
    setup do
      @human = users(:member)
      @workspace = workspaces(:shared)
      @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:curator),
        answering_user: users(:agent), title: "Conversation to organize")
      @return_to = workspace_conversations_path(@workspace,
        archived: "include", answering_user_public_id: @conversation.answering_user.public_id)
      @reader_path = conversation_path(@conversation, return_to: @return_to)
      sign_in_directly(@human)
    end
  end

  private

    def assert_management_page_fits
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end

    def assert_management_back_link(path)
      within("nav[aria-label='#{I18n.t("shared.back_navigation.back")}']") do
        assert_link href: path
      end
    end

    def archive_and_restore_conversation
      click_link I18n.t("conversation_management.archive.title"), exact: true
      assert_current_path new_conversation_archive_path(@conversation), ignore_query: true
      assert_text I18n.t("conversation_management.archive.side_effect")
      assert_text I18n.t("conversation_management.archive.accepted_work")
      assert_management_back_link @reader_path
      assert_management_page_fits
      click_button I18n.t("conversation_management.archive.submit"), exact: true
      assert_current_path @reader_path
      assert_text I18n.t("conversation_management.archive.saved")
      assert_predicate @conversation.reload, :archived?
      assert_no_link I18n.t("conversation_management.title.edit"), exact: true
      assert_management_back_link @return_to

      click_link I18n.t("conversation_management.unarchive.title"), exact: true
      assert_current_path new_conversation_unarchive_path(@conversation), ignore_query: true
      assert_text I18n.t("conversation_management.unarchive.side_effect")
      assert_text I18n.t("conversation_management.unarchive.no_restart")
      assert_management_page_fits
      click_button I18n.t("conversation_management.unarchive.submit"), exact: true
      assert_current_path @reader_path
      assert_text I18n.t("conversation_management.unarchive.saved")
      assert_not @conversation.reload.archived?
      assert_link I18n.t("conversation_management.title.edit"), exact: true
      assert_management_back_link @return_to
    end
end

class ConversationManagementJourneyTest < ApplicationSystemTestCase
  include ConversationManagementJourney

  test "a desktop title conflict requires explicit review before archive and restore" do
    visit @reader_path
    click_link I18n.t("conversation_management.title.edit"), exact: true
    assert_current_path edit_conversation_title_path(@conversation), ignore_query: true
    assert_management_back_link @reader_path
    fill_in I18n.t("conversation_management.title.label"), with: "My reviewed title"
    @conversation.reload.update!(title: "Changed in another tab")
    find_field(I18n.t("conversation_management.title.label")).send_keys(:tab)
    assert_focused "input[type='submit']", "the title form is keyboard reachable"
    find("input[type='submit']:focus").send_keys(:return)
    assert_selector "[role='alert']", text: I18n.t("conversation_management.title.conflict")
    assert_field I18n.t("conversation_management.title.label"), with: "My reviewed title"
    assert_text "Changed in another tab"
    assert_unchecked_field I18n.t("conversation_management.title.review_version")
    assert_equal "Changed in another tab", @conversation.reload.title
    assert_management_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-management-conflict-desktop.png"))

    check I18n.t("conversation_management.title.review_version")
    click_button I18n.t("conversation_management.title.save"), exact: true
    assert_current_path @reader_path
    assert_selector "h1", text: "My reviewed title"
    assert_equal "My reviewed title", @conversation.reload.title
    archive_and_restore_conversation
    assert_management_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-management-result-desktop.png"))
    within("nav[aria-label='#{I18n.t("shared.back_navigation.back")}']") { click_link }
    assert_current_path @return_to
  end
end

class MobileConversationManagementJourneyTest < MobileSystemTestCase
  include ConversationManagementJourney

  test "a narrow page handles a long title and completes a direct edit archive and restore" do
    @conversation.update!(title: "A" * 255)
    visit new_conversation_archive_path(@conversation, return_to: @return_to)
    assert_selector "h1", text: I18n.t("conversation_management.archive.title")
    assert_management_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-management-archive-mobile.png"))
    within("nav[aria-label='#{I18n.t("shared.back_navigation.back")}']") { click_link }
    assert_current_path @reader_path
    click_link I18n.t("conversation_management.title.edit"), exact: true
    assert_field I18n.t("conversation_management.title.label"), with: "A" * 255
    assert_management_page_fits
    fill_in I18n.t("conversation_management.title.label"), with: ""
    click_button I18n.t("conversation_management.title.save"), exact: true
    assert_current_path @reader_path
    assert_nil @conversation.reload.title
    assert_selector "h1", text: I18n.t("conversation_console.untitled")
    archive_and_restore_conversation
    assert_management_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-management-result-mobile.png"))
  end
end
