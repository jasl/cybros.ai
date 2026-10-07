require "test_helper"

# the approver's standing over HTTP against the new levels, and its deny twin. A loop-backed loop's
# adjudication verbs read the CONVERSATION's level — a principal the row lists at `read` is 403
# `not_authorized` before any task is looked at; a `full` entry releases and denies; `none` conceals
# the loop itself. Six requests.
class AgentAPI::V1::Workspaces::AgentRuns::AdjudicationStandingTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @creator = users(:agent)
    @curator = users(:curator)
    DevModelLane.ensure_enabled!(@account)
    @secret = create_access_token_fixture(user: @curator, name: "Curator").secret
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @creator, access_default: "read",
      default_runner_executor: suite_runner)
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @creator, approval_mode: "ask",
      approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
    @agent_run = seam.agent_run
    grow!(@agent_run, parallel(tool("first", "read_file"), tool("second", "read_file")), ask("done"))
    AgentRuns::ScheduleReady.call(agent_run_id: @agent_run.id)
    clear_enqueued_jobs
    assert_equal %w[needs_approval needs_approval],
      @agent_run.agent_run_tasks.where(node_key: %w[first second]).order(:node_key).pluck(:status)
  end

  def auth = { "Authorization" => "Bearer #{@secret}" }
  def tasks_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{@agent_run.public_id}/tasks"

  test "read is 403 on approve and deny, a full entry releases and denies, none is 404" do
    post "#{tasks_path}/first/approve", headers: auth
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    post "#{tasks_path}/second/deny", headers: auth, as: :json, params: { reason: "no" }
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
    assert_equal %w[needs_approval needs_approval],
      @agent_run.agent_run_tasks.where(node_key: %w[first second]).order(:node_key).pluck(:status)

    entry = @conversation.conversation_access_entries.create!(user: @curator, level: "full")
    post "#{tasks_path}/first/approve", headers: auth
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "dispatched", task["status"]
    assert_equal "human", task.dig("approval", "origin")
    assert_equal @curator.public_id, task.dig("approval", "decided_by")
    post "#{tasks_path}/second/deny", headers: auth, as: :json, params: { reason: "use ls" }
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "failed", task["status"]
    assert_equal({ "key" => "approval_denied", "detail" => "use ls" }, task.fetch("error"))

    entry.update!(level: "none")
    post "#{tasks_path}/first/approve", headers: auth
    assert_response :not_found
    post "#{tasks_path}/second/deny", headers: auth, as: :json, params: { reason: "no" }
    assert_response :not_found
  end
end
