require "test_helper"
require_relative "../test_helpers/schedules_console_test_helper"

class SchedulesConsoleTest < ActionDispatch::IntegrationTest
  include SchedulesConsoleTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @conversation = schedule_conversation(title: "Inbox workspace work")
    @job = console_schedule
    sign_in_as @human
  end

  test "Workspace and conversation lists keep filters, pagination and exact return paths" do
    hidden = console_schedule(conversation: schedule_conversation(creating_user: users(:owner), access_default: "none"))
    paused = console_schedule(name: "Paused inbox")
    paused.update!(status: "paused", next_run_at: nil)
    list = workspace_schedules_path(@workspace, status: "paused")
    get list
    assert_response :success
    assert_select "article[data-schedule-id='#{paused.public_id}']", 1
    [@job, hidden].each { |job| assert_select "article[data-schedule-id='#{job.public_id}']", 0 }
    detail = conversation_schedule_path(@conversation, paused, return_to: list)
    assert_select "a[href=?]", detail
    get detail
    assert_response :success
    assert_select "nav a[href=?]", list
    get conversation_schedules_path(@conversation), params: { limit: 1 }
    assert_response :success
    assert_select "article[data-schedule-id]", 1
    next_page = response.parsed_body.css("a").find { |link| link.text == "Next page" }["href"]
    get next_page
    assert_response :success
    assert_select "article[data-schedule-id]", 1
    get workspace_schedules_path(workspaces(:personal))
    assert_response :not_found
  end

  test "commands use the parent scope and preserve the original creator and clock" do
    clock = @job.next_run_at
    post conversation_schedule_pause_path(@conversation, @job)
    assert_response :see_other
    assert_predicate @job.reload, :paused?
    post conversation_schedule_run_path(@conversation, @job)
    assert_response :see_other
    child = @job.reload.last_execution_conversation
    assert_equal @human, child.creating_user
    assert_equal @job.answering_user, child.answering_user
    assert_predicate @job, :paused?
    assert_nil @job.next_run_at
    post conversation_schedule_run_path(@conversation, @job)
    assert_response :conflict
    assert_select "[role='alert']", text: /previous execution is still unfinished/
    assert_equal 1, @job.execution_conversations.count
    assert_select "a[href*=?]", "/inputs/#{child.scheduled_input_public_id}"
    post conversation_schedule_resume_path(@conversation, @job)
    assert_response :see_other
    assert_equal clock, @job.reload.next_run_at
    post conversation_schedule_cancel_path(@conversation, @job)
    assert_response :see_other
    assert_predicate @job.reload, :canceled?
    assert_empty child.inputs
    other = schedule_conversation
    post conversation_schedule_pause_path(other, @job)
    assert_response :not_found
  end

  test "a completed once clock can cancel its still waiting input" do
    at = Time.current + 1.hour
    once = console_schedule(rule: { "kind" => "once", "run_at" => at.iso8601(6) })
    assert_equal :dispatched, Schedules::Dispatch.call(id: once.id, cutoff: at)
    assert_predicate once.reload, :completed?
    get conversation_schedule_path(@conversation, once)
    assert_response :success
    assert_select "button", text: "Cancel schedule"
    assert_select "button", text: "Run now", count: 0
    post conversation_schedule_cancel_path(@conversation, once)
    assert_response :see_other
    assert_empty once.last_execution_conversation.inputs
  end

  test "a reader can inspect but not invoke commands and a hidden parent stays absent for an admin" do
    read_conversation = schedule_conversation(creating_user: users(:owner), access_default: "read")
    read_job = console_schedule(conversation: read_conversation)
    get conversation_schedule_path(read_conversation, read_job)
    assert_response :success
    assert_select "form[action$='/run']", 0
    assert_select "form[action$='/pause']", 0
    [:pause, :resume, :cancel, :run].each do |command|
      post "/conversations/#{read_conversation.public_id}/schedules/#{read_job.public_id}/#{command}"
      assert_response :forbidden
    end
    @conversation.update!(access_default: "none")
    sign_out
    sign_in_as users(:owner)
    get conversation_schedule_path(@conversation, @job)
    assert_response :not_found
    post conversation_schedule_cancel_path(@conversation, @job)
    assert_response :not_found
  end

  test "latest execution and history independently conceal a child and retain a readable pending input" do
    post conversation_schedule_run_path(@conversation, @job)
    child = @job.reload.last_execution_conversation
    get conversation_schedule_path(@conversation, @job)
    assert_select "article[data-execution-id='#{child.public_id}']", 1
    child.conversation_access_entries.create!(user: users(:curator), level: "none")
    sign_out
    sign_in_as users(:curator)
    get conversation_schedule_path(@conversation, @job)
    assert_response :success
    assert_select "article[data-execution-id]", 0
    get conversation_schedule_executions_path(@conversation, @job)
    assert_response :success
    assert_select "article[data-execution-id]", 0
  end

  test "an unauthenticated request cannot read schedules" do
    sign_out
    get workspace_schedules_path(@workspace)
    assert_redirected_to new_session_path(return_to: workspace_schedules_path(@workspace))
  end
end
