require "test_helper"
require_relative "../test_helpers/schedules_console_test_helper"

class ScheduleResultsConsoleTest < ActionDispatch::IntegrationTest
  include SchedulesConsoleTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @conversation = schedule_conversation
    @job = console_schedule
    assert_equal :dispatched, Schedules::Dispatch.call(id: @job.id, by: @human)
    @child = @job.reload.last_execution_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: @child.id)
    assert_predicate materialized, :accepted?
    @turn = materialized.value
    @original = @turn.active_variant
    @original.update!(status: "failed")
    @fallback = @turn.variants.create!(position: 1, source: "fallback", status: "completed",
      origin_variant: @original, provider_id: "dev", model_ref: "mock-unmetered", details_pruned_at: Time.current)
    ContentBodies::Replace.call(owner: @fallback, role: "content",
      entries: [{ "text" => "<script>Scheduled fallback answer</script>" }], seal: true)
    @turn.update!(status: "completed", active_variant: @fallback)
    sign_in_as @human
  end

  test "schedule history opens the automatic fallback even after another candidate becomes active" do
    manual = @turn.variants.create!(position: 2, source: "inference", status: "completed", origin_variant: @original)
    ContentBodies::Replace.call(owner: manual, role: "content", entries: [{ "text" => "Unrelated manual answer" }], seal: true)
    @turn.update!(active_variant: manual)
    history = conversation_schedule_executions_path(@conversation, @job)
    exact = conversation_turn_variant_path(@child, @turn.public_id, @fallback.public_id, return_to: history)
    get history
    assert_response :success
    assert_select "a[href=?]", exact
    get exact
    assert_response :success
    assert_select "[data-variant-id='#{@fallback.public_id}']", 1
    assert_select "[data-variant-id='#{manual.public_id}']", 0
    assert_select "nav a[href=?]", history
    assert_includes response.body, "&lt;script&gt;Scheduled fallback answer&lt;/script&gt;"
    assert_select "script", text: "Scheduled fallback answer", count: 0
    assert_not_includes response.body, "Unrelated manual answer"
    assert_select "a[href^='/runs/']", 0
    @fallback.update!(deleted_at: Time.current)
    get exact
    assert_response :not_found
  end

  test "a known result address does not bypass turn visibility or the child ACL" do
    exact = conversation_turn_variant_path(@child, @turn.public_id, @fallback.public_id)
    @turn.update!(visibility: "hidden")
    get exact
    assert_response :not_found
    @turn.update!(visibility: "visible")
    @child.conversation_access_entries.create!(user: users(:curator), level: "none")
    sign_out
    sign_in_as users(:curator)
    get exact
    assert_response :not_found
  end

  test "multiple automatic fallbacks stay on the original chain while a manual candidate is active" do
    @fallback.update!(status: "failed")
    final = @turn.variants.create!(position: 2, source: "fallback", status: "running",
      origin_variant: @fallback, provider_id: "dev", model_ref: "mock-text")
    manual = @turn.variants.create!(position: 3, source: "inference", status: "completed", origin_variant: @original)
    @turn.update!(active_variant: manual)
    projected = Schedules::ExecutionProjection.call([@child.id]).fetch(@child.id)
    assert_equal final.public_id, projected.fetch(:variant_public_id)
    assert_equal "running", projected.fetch(:status)
    assert_nil projected.fetch(:run_public_id)

    final.update!(status: "completed", details_pruned_at: Time.current)
    ContentBodies::Replace.call(owner: final, role: "content", entries: [{ "text" => "Second fallback answer" }], seal: true)
    history = conversation_schedule_executions_path(@conversation, @job)
    exact = conversation_turn_variant_path(@child, @turn.public_id, final.public_id, return_to: history)
    get history
    assert_response :success
    assert_select "a[href=?]", exact
    get exact
    assert_response :success
    assert_select "[data-variant-id='#{final.public_id}']", 1
    assert_select "[data-variant-id='#{@fallback.public_id}']", 0
    assert_select "[data-variant-id='#{manual.public_id}']", 0
    assert_includes response.body, "Second fallback answer"
  end
end
