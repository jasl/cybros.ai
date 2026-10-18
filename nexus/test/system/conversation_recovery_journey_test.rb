require "application_system_test_case"
require_relative "../test_helpers/conversation_recovery_test_helper"

module ConversationRecoveryJourney
  extend ActiveSupport::Concern
  include ConversationRecoveryTestHelper

  included do
    include ActiveJob::TestHelper
    setup { prepare_recovery_conversation }
  end

  private

    def sign_in_for_recovery
      sign_in_directly(@human)
    end

    def assert_recovery_page_fits
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end

class ConversationRecoveryJourneyTest < ApplicationSystemTestCase
  include ConversationRecoveryJourney

  test "a held Run returns from a versioned cost edit and retries only its failed model Task" do
    held_run_with_completed_tool
    preserved = @tool.reload.attributes.slice("status", "execution_generation", "completed_at", "output_summary")
    output_id = @tool.output_body.id
    sign_in_for_recovery
    task_path = run_task_path(@run, @failed_task.node_key)
    visit task_path
    assert_selector "[data-cost-recovery]"
    within("[data-cost-recovery]") { click_link "Edit cost limit" }
    assert_current_path edit_conversation_cost_limit_path(@conversation), ignore_query: true
    assert_text I18n.t("conversation_console.known_cost")
    fill_in "Cost limit (USD)", with: "2.5000"
    # Another ordinary edit creates a real stale form. Saving must leave the
    # draft visible until the person explicitly adopts the current version.
    @conversation.reload.update!(title: "Cost recovery changed")
    click_button "Save cost limit"
    assert_selector "[role=alert]", text: "The Conversation changed"
    assert_field "Cost limit (USD)", with: "2.5000"
    assert_equal 0.to_d, @conversation.reload.cost_limit
    assert_recovery_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/cost-recovery-conflict-desktop.png"))
    click_button "Save my draft using the current version"
    assert_current_path task_path
    assert_equal BigDecimal("2.5"), @conversation.reload.cost_limit
    assert_equal "needs_attention", @run.reload.status
    confirm_through_dialog { click_button I18n.t("runs_console.retry"), exact: true }
    assert_text I18n.t("runs_console.command_accepted")
    assert_equal 1, @failed_task.reload.execution_generation
    assert_equal preserved, @tool.reload.attributes.slice(*preserved.keys)
    assert_equal output_id, @tool.output_body.id
    schedule_loop!(@run)
    run_loop_round!(@run, sse_success("Resumed the original execution"))
    Conversations::Turns::Converge.call
    visit conversation_turn_variant_path(@conversation, @turn.public_id, @original.public_id)
    assert_text "Resumed the original execution"
    assert_equal "completed", @run.reload.status
    assert_recovery_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/cost-recovery-result-desktop.png"))
  end
end

class MobileConversationRecoveryJourneyTest < MobileSystemTestCase
  include ConversationRecoveryJourney

  test "a direct reply clears its cap and explains continuation in the application on a narrow screen" do
    cost_refused_reply
    sign_in_for_recovery
    original_path = conversation_turn_variant_path(@conversation, @turn.public_id, @original.public_id)
    visit original_path
    assert_selector "[data-cost-recovery]"
    within("[data-cost-recovery]") { click_link "Edit cost limit" }
    fill_in "Cost limit (USD)", with: ""
    click_button "Save cost limit"
    assert_current_path original_path
    assert_nil @conversation.reload.cost_limit
    assert_equal "failed", @original.reload.status
    assert_selector "[data-cost-recovery]"
    assert_text I18n.t("management_console.continue_in_app")
    assert_no_link "Regenerate reply", exact: true
    assert_equal 1, @turn.variants.count
    assert_recovery_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/cost-recovery-result-mobile.png"))
  end
end
