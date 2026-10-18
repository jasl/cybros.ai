require "application_system_test_case"

module RelatedConversationsJourney
  extend ActiveSupport::Concern

  included do
    test "related conversation lists preserve their source and exact return path" do
      human = users(:member)
      workspace = workspaces(:shared)
      parent = Conversation.create!(workspace: workspace, creating_user: human, title: "Review parent")
      seam = create_run_backed_turn(conversation: parent, acting_user: human,
        turn_status: "completed", variant_status: "completed", run_status: "completed")
      child = Conversation.create!(workspace: workspace, creating_user: human, title: "Review child",
        parent_conversation: parent, parent_conversation_public_id: parent.public_id)
      fork = Conversation.create!(workspace: workspace, creating_user: human, title: "Review fork")
      side = Conversation.create!(workspace: workspace, creating_user: human, title: "Review side", side: true)
      [fork, side].each do |row|
        row.conversation_ancestries.create!(account: parent.account, ancestor_conversation: parent,
          depth: 1, boundary_position: seam.turn.position)
      end
      source = conversation_path(parent, return_to: workspace_conversations_path(workspace))
      sign_in_directly(human)
      visit source

      { "Subagent conversations" => child, "Forked conversations" => fork, "Side conversations" => side }.each do |label, row|
        click_link label, exact: true
        assert_selector "h1", text: label
        list_path = URI(page.current_url).request_uri
        assert_selector "tr[data-conversation-id]", count: 1
        click_link row.title, exact: true
        assert_current_path conversation_path(row, return_to: list_path)
        within("main nav[aria-label='Back']") { click_link "Back", exact: true }
        assert_current_path list_path
        assert_selector "tr[data-conversation-id='#{row.public_id}']"
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
          page.evaluate_script("document.documentElement.clientWidth") + 1
        page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}-#{row.title.parameterize}.png"))
        within("main nav[aria-label='Back']") { click_link parent.title, exact: true }
        assert_current_path source
      end
    end
  end
end

class RelatedConversationsJourneyTest < ApplicationSystemTestCase
  include RelatedConversationsJourney
end

class MobileRelatedConversationsJourneyTest < MobileSystemTestCase
  include RelatedConversationsJourney
end
