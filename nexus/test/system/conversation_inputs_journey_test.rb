require "application_system_test_case"

module ConversationInputsJourney
  extend ActiveSupport::Concern
  include InvocationHarness

  included do
    include ActiveJob::TestHelper

    setup do
      @previous_forgery_protection = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
    end

    teardown { ActionController::Base.allow_forgery_protection = @previous_forgery_protection }

    test "read an application input follow its exact result and cancel later pending input" do
      human = users(:member)
      agent = create_agent_member(steward: human, agent_identifier: "inputs.browser")
      agent.update!(default_model: "dev/mock-text")
      DevModelLane.ensure_enabled!(accounts(:cybros))
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human,
        answering_user: agent, title: "Application work")
      input = accept_input(conversation, human, "The accepted request")
      sign_in_directly(human)
      visit conversation_path(conversation)
      assert_no_link "Send new input"
      click_link "Pending inputs", exact: true
      assert_text "The accepted request"
      pending_path = URI.parse(page.current_url).request_uri
      click_link "Follow this input", exact: true
      follow_path = conversation_input_path(conversation, input.public_id, return_to: pending_path)
      assert_current_path follow_path
      assert_link "Back", href: pending_path
      assert_no_link "Correct this input"
      assert_button "Cancel pending input"

      Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      turn = conversation.turns.sole
      variant = turn.active_variant
      attempt = ModelInvocations::AdmitQueuedWork.call.admitted.sole.attempt
      apply_via(attempt, sse_success("The application request is complete."))
      Conversations::Turns::Converge.call
      visit follow_path
      assert_text "The application request is complete."
      assert_selector "[data-variant-id='#{variant.public_id}']"
      assert_no_button "Cancel pending input"
      click_link "Open Conversation at this turn", exact: true
      assert_text "The application request is complete."
      pending = accept_input(conversation, human, "A request to withdraw")
      visit pending_path
      assert_selector "meta[name=referrer][content=no-referrer]", visible: :all
      click_link "Follow this input", exact: true
      assert_selector "meta[name=referrer][content=same-origin]", visible: :all
      assert_selector "meta[name=referrer]", count: 1, visible: :all
      click_button "Cancel pending input"
      assert_current_path pending_path
      assert_selector "meta[name=referrer][content=no-referrer]", visible: :all
      assert_text "Pending input canceled"
      assert_text "No pending inputs"
      assert_not Input.exists?(pending.id)
      assert_equal "completed", variant.reload.status
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
      page.save_screenshot(Rails.root.join("tmp/screenshots/conversation-inputs-#{self.class.name.underscore}.png"))
    end
  end

  private

    def accept_input(conversation, human, text)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: human, kind: "direct_reply", role: "user", entries: [{ "text" => text }],
        visible_in_context: nil, delivery_mode: "queue", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil, provider_id: "dev", model_ref: "mock-text",
        reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?
      result.value
    end
end

class ConversationInputsJourneyTest < ApplicationSystemTestCase
  include ConversationInputsJourney
end

class MobileConversationInputsJourneyTest < MobileSystemTestCase
  include ConversationInputsJourney
end
