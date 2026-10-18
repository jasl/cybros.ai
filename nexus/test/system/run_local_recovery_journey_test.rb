require "application_system_test_case"
require_relative "../test_helpers/runs_result_delivery_test_helper"
require_relative "../test_helpers/compaction_test_helper"

class RunBranchRecoveryJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include RunsResultDeliveryTestHelper

  setup do
    @previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown { ActionController::Base.allow_forgery_protection = @previous_forgery_protection }

  test "a human cancels work owned by a completed launcher and keeps the other work" do
    _turn, run = open_turn!("Review two parts of the report")
    call_round!(run, "r1", "delegate_task", { prompt: "Review the first part" }, { prompt: "Review the second part" })
    launcher = loop_node(run, "r2t0")
    branch = loop_node(run, "r2t0-model-1")
    sibling = loop_node(run, "r2t1-model-1")
    mainline = loop_node(run, "r2")
    assert_equal "completed", launcher.status
    preserved = [sibling.status, mainline.status]

    sign_in_directly(@human)
    visit run_task_path(run, launcher.node_key, return_to: run_tasks_path(run))
    assert_button "Cancel branch"
    page.scroll_to(find("#task-recovery-heading"), align: :center)
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-branch-cancel-desktop.png"))
    click_button "Cancel branch"
    assert_selector "#turbo-confirm[open]", text: "Completed effects are kept"
    find("#turbo-confirm[open] .modal-action button[value='cancel']").click
    assert_equal "running", branch.reload.status
    confirm_through_dialog { click_button "Cancel branch" }
    assert_text "Cancellation request accepted"
    assert_current_path run_task_path(run, launcher.node_key), ignore_query: true
    Runs::ConvergeTerminalSteps.call
    visit current_url
    assert_no_button "Cancel branch"
    assert_equal "canceled", branch.reload.status
    assert_equal preserved, [sibling.reload.status, mainline.reload.status]
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-branch-recovery-desktop.png"))
  end
end

class RunCompactionRecoveryJourneyTest < MobileSystemTestCase
  include ActiveJob::TestHelper
  include CompactionTestHelper

  setup do
    @previous_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown { ActionController::Base.allow_forgery_protection = @previous_forgery_protection }

  test "a paused model task follows its summary and resumes on a narrow screen" do
    run = create_loop!(model("round1", "prompt" => "Read the report"),
      model("round2", "prompt" => "Write the conclusion"))
    settle!(run, "round1", "The report compares two proposals.")
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human)), :accepted?
    source_path = run_task_path(run, "round2", return_to: run_tasks_path(run))

    sign_in_directly(@human)
    visit source_path
    assert_button "Compact context"
    assert_text "This Run is paused"
    confirm_through_dialog { click_button "Compact context" }
    assert_text "Compaction request accepted"
    assert_predicate run.reload, :paused?
    summary = node(run, "round2").compaction.fetch(Tasks::ModelTask::SUMMARY_SOURCE)
    assert_equal "queued", node(run, summary).status
    assert_no_button "Compact context"
    assert_text "The summary is not ready yet"
    assert_viewport_contains_page
    page.scroll_to(find("#task-recovery-heading"), align: :center)
    page.save_screenshot(Rails.root.join("tmp/screenshots/run-compaction-recovery-mobile.png"))
    click_link "View current compaction step"
    assert_current_path run_task_path(run, summary), ignore_query: true
    click_link "Back to work"
    assert_current_path source_path

    click_button "Resume", exact: true
    assert_button "Pause", exact: true
    assert_predicate run.reload, :running?
    schedule!(run)
    settle!(run, summary, "The first proposal has lower cost; the second has wider scope.")
    visit source_path
    assert_text "A usable summary is available"
    click_link "View current compaction step"
    assert_text "The first proposal has lower cost; the second has wider scope."
    assert_viewport_contains_page
  end

  private

    def assert_viewport_contains_page
      viewport = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport + 1
    end
end
