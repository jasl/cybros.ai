require "application_system_test_case"
require_relative "../test_helpers/runs_result_delivery_test_helper"

module RunSteeringJourney
  extend ActiveSupport::Concern
  include RunsResultDeliveryTestHelper

  included do
    include ActiveJob::TestHelper

    setup do
      @previous_forgery_protection = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
    end

    teardown { ActionController::Base.allow_forgery_protection = @previous_forgery_protection }
  end

  private

    def sign_in_through_form
      visit new_session_url
      fill_in "Email", with: @human.email
      fill_in "Password", with: "password"
      click_button "Sign in"
      assert_text "Overview"
    end

    def submit_correction_form(label)
      previous_body = find("body", visible: :all).native
      click_button label
      # A refused non-Turbo form can keep its URL. Wait for the replacement
      # document before checking the retained draft or the command result.
      assert_selector("body", visible: :all) { |body| body.native != previous_body }
    end

    def create_correction(run, text)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: @conversation, acting_user: @human, kind: "direct_reply", role: "user", entries: [{ "text" => text }],
        visible_in_context: nil, delivery_mode: "steer", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil, expected_steering_run_public_id: run.public_id,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
      ))
      assert_predicate result, :accepted?
      result.value
    end

    def assert_correction_page_fits
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end

    def assert_no_browser_errors(conflict_path: nil)
      errors = page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
      if conflict_path
        # The preserved-draft page deliberately returns the asserted 409.
        url = URI.join(page.current_url, conflict_path).to_s
        errors.reject! { |entry| entry.message.match?(/\A#{Regexp.escape(url)} - Failed to load resource: .*\b409\b/) }
      end
      assert_empty errors
    end
end

class RunSteeringJourneyTest < ApplicationSystemTestCase
  include RunSteeringJourney

  test "a signed-in human reads an application correction and follows its exact model request" do
    turn, run = open_turn!("Read the report before answering")
    call_round!(run, "r1", "read_file", { path: "report.txt" })
    tool = run.tasks.where(tool_name: "read_file").sole
    assert_equal "dispatched", tool.status
    original_request = round_request_entries(loop_node(run, "r1"))

    sign_in_through_form
    origin = workspace_runs_path(@workspace, kind: "all", status: "running")
    corrections = run_steers_path(run, return_to: origin)
    visit run_path(run, return_to: origin)
    click_link "Text corrections", exact: true
    assert_current_path corrections
    assert_text "No waiting corrections"
    input = create_correction(run, "Compare the costs before discussing the schedule.")
    original_body = input.content_body.id
    follow_path = run_steering_observation_path(run, input_public_id: input.public_id, return_to: origin)
    visit follow_path
    assert_current_path follow_path
    assert_selector "[data-input-id='#{input.public_id}'] .badge", text: "Waiting", exact_text: true
    assert_equal run.public_id, input.expected_steering_run_public_id
    assert_equal "steer", input.delivery_mode
    click_link "Text corrections", exact: true
    assert_selector "[data-input-id='#{input.public_id}']", text: input.text
    click_link "Follow this correction", exact: true
    assert_current_path follow_path
    assert_no_button "Process as soon as possible"
    assert_selector "form[action='#{run_steer_cancellation_path(run, input.public_id, return_to: origin)}']"
    assert_correction_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-correction-waiting-desktop.png"))

    result = Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(
      host: @conversation, input_public_id: input.public_id, acting_user: @human,
      expected_lock_version: input.lock_version, delivery_mode: "steer_now", entries: nil,
      visible_in_context: nil, context_mode: nil, context_options: nil, provider_id: nil,
      model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?
    assert_equal "steer_now", input.reload.delivery_mode
    assert_equal original_body, input.content_body.id
    assert_equal run.public_id, input.expected_steering_run_public_id
    assert_no_button "Process as soon as possible"
    schedule_loop!(run)

    landed = @conversation.event_items.where(item_type: "input_materialized")
      .find_by!("payload ->> 'input_public_id' = ?", input.public_id)
    task = run.tasks.find_by!(node_key: landed.payload.fetch("task_key"))
    assert_equal run.public_id, landed.payload.fetch("run_public_id")
    assert_not Input.exists?(input.id)
    assert_equal "dispatched", tool.reload.status
    assert_equal original_request, round_request_entries(loop_node(run, "r1"))

    visit follow_path
    assert_text "Added to a model request"
    assert_text I18n.t("run_steering.consumed_scope")
    assert_no_button "Cancel correction"
    assert_correction_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-correction-consumed-desktop.png"))
    click_button "Refresh", exact: true
    assert_current_path follow_path
    click_link "View the model task", exact: true
    assert_current_path run_task_path(run, task.node_key), ignore_query: true
    click_link "Sealed model request", exact: true
    assert_current_path run_task_request_path(run, task.node_key), ignore_query: true
    assert_text "Compare the costs before discussing the schedule."
    visit follow_path
    click_link "View the original candidate", exact: true
    assert_current_path conversation_turn_variant_path(@conversation, turn.public_id, run.variant.public_id), ignore_query: true
    visit follow_path
    click_link "Back to work", exact: true
    assert_current_path origin
    assert_select "Run type", selected: "All runs"
    assert_no_browser_errors
  end
end

class MobileRunSteeringJourneyTest < MobileSystemTestCase
  include RunSteeringJourney

  test "a narrow screen can cancel an application correction without stopping its Run" do
    _turn, current_run = open_turn!("Review the original proposal")
    input = create_correction(current_run, "请保留这次执行的原始证据。")
    sign_in_through_form
    origin = workspace_runs_path(@workspace, kind: "all", status: "running")
    corrections = run_steers_path(current_run, return_to: origin)
    follow_path = run_steering_observation_path(current_run, input_public_id: input.public_id, return_to: origin)
    visit follow_path
    assert_current_path follow_path
    assert_equal current_run.public_id, input.expected_steering_run_public_id
    assert_selector "form[action='#{run_steer_cancellation_path(current_run, input.public_id, return_to: origin)}']"
    submit_correction_form "Cancel correction"
    assert_current_path follow_path
    assert_selector "[data-input-id='#{input.public_id}'] .badge", text: "Canceled", exact_text: true
    assert_text I18n.t("run_steering.canceled_scope")
    assert_no_button "Cancel correction"
    assert_no_button "Process as soon as possible"
    assert_not Input.exists?(input.id)
    assert_equal "running", current_run.reload.status
    assert_correction_page_fits
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-correction-canceled-mobile.png"))

    click_link "Text corrections", exact: true
    assert_current_path corrections
    assert_text "No waiting corrections"
    visit follow_path
    assert_selector "[data-input-id='#{input.public_id}'] .badge", text: "Canceled", exact_text: true
    assert_text "Original Run: #{current_run.public_id}"
    click_link "Back to work", exact: true
    assert_current_path origin
    assert_select "Run type", selected: "All runs"
    assert_no_browser_errors
  end
end
