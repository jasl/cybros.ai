require "application_system_test_case"
require_relative "../test_helpers/runs_result_delivery_test_helper"

module ConversationCancellationJourney
  extend ActiveSupport::Concern
  include RunsResultDeliveryTestHelper

  included do
    include ActiveJob::TestHelper

    setup do
      @conversation.update!(title: "Review stopping this conversation's existing work — #{"long-title-" * 16}")
    end

    test "stop a direct reply without a Run and follow the ordinary queued input that survives" do
      declare_tools!(@agent, tools: [], default_model: "dev/mock-text")
      input = post_input!(@conversation, acting_user: @human, text: "The original direct request",
        kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.turns.find_by!(input_public_id: input.public_id)
      original = turn.active_variant
      invocation = original.model_invocation
      assert_nil original.run
      queued = post_input!(@conversation.reload, acting_user: @human, text: "Keep this next independent request",
        kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
      queued_attributes = queued.attributes
      list_path = workspace_conversations_path(@workspace, query: "original direct request")
      reader_path = conversation_path(@conversation, around_turn_public_id: turn.public_id, return_to: list_path)

      sign_in_through_form
      visit reader_path
      assert_no_link I18n.t("conversation_console.current_execution"), exact: true
      within("[data-variant-id='#{original.public_id}']") do
        assert_selector ".badge", text: "Running", exact_text: true
        assert_no_link I18n.t("conversation_console.view_run"), exact: true
      end
      open_stop_confirmation(reader_path)
      assert_stop_page_fits
      page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}-confirmation.png"))
      click_link "Return to conversation", exact: true
      assert_current_path reader_path
      open_stop_confirmation(reader_path)
      submit_stop_form

      assert_current_path reader_path
      assert_text I18n.t("conversation_cancellation.accepted")
      assert_equal "canceled", invocation.reload.status
      assert_equal queued_attributes, queued.reload.attributes
      assert_equal 1, @conversation.turns.count
      assert_equal 1, turn.variants.count

      # Only the normal converger settles the candidate. No provider delay or
      # background worker is needed to keep the Stop button reachable.
      Conversations::Turns::Converge.call
      click_button "Refresh", exact: true
      assert_current_path reader_path
      within("[data-variant-id='#{original.public_id}']") do
        assert_selector ".badge", text: "Canceled", exact_text: true
        assert_no_link I18n.t("conversation_console.view_run"), exact: true
      end
      assert_equal 1, @conversation.turns.count
      assert_stop_page_fits
      page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}-direct-canceled.png"))

      click_link "Pending inputs", exact: true
      pending_path = conversation_inputs_path(@conversation, return_to: reader_path)
      assert_current_path pending_path
      within("[data-input-id='#{queued.public_id}']") do
        assert_text "Keep this next independent request"
        click_link "Follow this input", exact: true
      end
      follow_path = conversation_input_path(@conversation, queued.public_id, return_to: pending_path)
      assert_current_path follow_path
      assert_link "Back", href: pending_path
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      next_turn = @conversation.turns.find_by!(input_public_id: queued.public_id)
      next_variant = next_turn.active_variant
      complete_direct_reply(next_variant, "The queued request still completed.")
      click_button "Refresh", exact: true
      assert_current_path follow_path
      assert_selector "[data-variant-id='#{next_variant.public_id}']", text: "The queued request still completed."
      assert_equal "canceled", original.reload.status
      assert_equal "completed", next_variant.reload.status
      assert_not Input.exists?(id: queued.id)
      assert_stop_page_fits
      assert_no_browser_errors
    end

    test "stop earlier background work with no current Run then inspect its original Run and an idle refusal" do
      turn, run = delivered_turn!
      Conversations::Turns::Converge.call
      original = turn.reload.active_variant
      assert_equal "completed", original.status
      assert_equal "running", run.reload.status
      published = original.content_bodies.find_by!(role: "content").effective_text
      later = post_input!(@conversation.reload, acting_user: @human, text: "A later note with no new execution")
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      later_turn = @conversation.turns.find_by!(input_public_id: later.public_id)
      assert_operator later_turn.position, :>, turn.position
      assert_nil @conversation.reload.active_turn_id
      reader_path = conversation_path(@conversation, around_turn_public_id: turn.public_id,
        return_to: workspace_conversations_path(@workspace))

      sign_in_through_form
      visit reader_path
      assert_no_link I18n.t("conversation_console.current_execution"), exact: true
      assert_text published
      assert_text "A later note with no new execution"
      open_stop_confirmation(reader_path)
      submit_stop_form
      assert_current_path reader_path
      assert_text I18n.t("conversation_cancellation.accepted")
      assert_predicate run.reload, :stopped?

      # The source cut wakes the existing scheduler; advance that owner
      # explicitly instead of requiring a transient canceling page to appear.
      schedule_loop!(run)
      Runs::ConvergeTerminalSteps.call
      schedule_loop!(run)
      Conversations::Turns::Converge.call
      assert_equal "canceled", run.reload.status
      assert_equal "completed", original.reload.status
      assert_equal published, original.content_bodies.find_by!(role: "content").effective_text
      within("[data-variant-id='#{original.public_id}']") do
        assert_selector ".badge", text: "Completed", exact_text: true
        click_link I18n.t("conversation_console.view_run"), exact: true
      end
      assert_current_path run_path(run, return_to: reader_path)
      assert_text run.public_id
      assert_selector "main header p", text: "Canceled · #{@workspace.name}", exact_text: true
      assert_stop_page_fits
      page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}-background-canceled.png"))
      within("main nav[aria-label='Back']") { click_link I18n.t("runs_console.back"), exact: true }
      assert_current_path reader_path
      assert_text published
      open_stop_confirmation(reader_path)
      submit_stop_form
      assert_current_path conversation_cancellation_path(@conversation)
      assert_selector "[role='alert']", text: I18n.t("conversation_cancellation.not_running")
      assert_no_text I18n.t("conversation_cancellation.accepted")
      assert_equal reader_path, find("input[name='return_to']", visible: :all).value
      assert_stop_page_fits
      page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}-nothing-to-stop.png"))
      click_link "Return to conversation", exact: true
      assert_current_path reader_path
      assert_text published
      assert_no_browser_errors(conflict_path: conversation_cancellation_path(@conversation))
    end
  end

  private

    def sign_in_through_form
      visit new_session_url
      fill_in "Email", with: @human.email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Overview"
    end

    def open_stop_confirmation(reader_path)
      click_link "Stop conversation work", exact: true
      assert_current_path new_conversation_cancellation_path(@conversation, return_to: reader_path)
      assert_selector "main h1", text: "Stop conversation work", exact_text: true
      assert_text @conversation.title
      %w[scope queued preserved follow].each do |key|
        assert_text I18n.t("conversation_cancellation.#{key}")
      end
      within("form[action='#{conversation_cancellation_path(@conversation)}'][method='post']") do
        assert_not_empty find("input[name='authenticity_token']", visible: :all).value
        assert_equal reader_path, find("input[name='return_to']", visible: :all).value
      end
    end

    def submit_stop_form
      previous_body = find("body", visible: :all).native
      click_button "Stop conversation work", exact: true
      # A non-Turbo 409 keeps the form, so await its new document before
      # inspecting feedback or navigating back to the original history window.
      assert_selector("body", visible: :all) { |body| body.native != previous_body }
    end

    def complete_direct_reply(variant, text)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |work|
        work.attempt.model_invocation_id == variant.model_invocation_id
      end
      assert admitted, "the queued input's original candidate must be admitted"
      apply_via(admitted.attempt, sse_success(text))
      Conversations::Turns::Converge.call
    end

    def assert_stop_page_fits
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end

    def assert_no_browser_errors(conflict_path: nil)
      errors = page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
      if conflict_path
        # The second deliberate Stop renders the asserted not_running 409.
        url = URI.join(page.current_url, conflict_path).to_s
        errors.reject! { |entry| entry.message.match?(/\A#{Regexp.escape(url)} - Failed to load resource: .*\b409\b/) }
      end
      assert_empty errors
    end
end

class ConversationCancellationJourneyTest < ApplicationSystemTestCase
  include ConversationCancellationJourney
end

class MobileConversationCancellationJourneyTest < MobileSystemTestCase
  include ConversationCancellationJourney
end
