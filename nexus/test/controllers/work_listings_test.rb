require "test_helper"

class WorkListingsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @creator = users(:agent)
    sign_in_as @human
  end

  test "Workspace runs hide inaccessible work before pagination and use public routes" do
    visible = hosted_run(title: "Readable work")
    hidden = hosted_run(title: "Hidden work", access_default: "none")
    private_run = standalone_run(workspace: workspaces(:personal))
    standalone = standalone_run
    get workspace_runs_path(@workspace), params: { limit: 1, order: "asc", kind: "all" }
    assert_response :success
    assert_select "article[data-run-id='#{visible.public_id}']", 1
    assert_select "a[href=?]", run_path(visible, return_to: request.fullpath)
    [hidden, private_run, standalone].each do |run|
      assert_select "article[data-run-id='#{run.public_id}']", 0
    end
    next_page = css_select("a").find { |link| link.text == "Next page" }["href"]
    get next_page
    assert_response :success
    assert_select "article[data-run-id='#{standalone.public_id}']", 1
    assert_select "article[data-run-id='#{hidden.public_id}']", 0
    assert_select "article[data-run-id='#{private_run.public_id}']", 0
  end

  test "run filters use creation time and canonical statuses for both member and browser" do
    run = standalone_run
    run.update!(created_at: Time.utc(2026, 10, 10, 2), status: "paused")
    outside = standalone_run
    outside.update!(created_at: Time.utc(2026, 10, 11, 2))
    filters = { from: "2026-10-10T00:00:00Z", to: "2026-10-11T00:00:00Z", status: "paused", kind: "standalone" }
    get workspace_runs_path(@workspace), params: filters
    assert_response :success
    assert_select "article[data-run-id='#{run.public_id}']", 1
    assert_select "article[data-run-id='#{outside.public_id}']", 0
    get "/agent_api/v1/runs", params: filters, headers: member_headers
    assert_response :success
    assert_equal [run.public_id], response.parsed_body.fetch("runs").pluck("public_id")
    assert_equal @workspace.public_id, response.parsed_body.fetch("runs").sole.fetch("workspace_public_id")
    get workspace_runs_path(@workspace), params: { status: "failed" }
    assert_response :bad_request
  end

  test "agent association includes frozen conversation answerers and standalone creators before pagination" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: @human, title: "Agent answer")
    hosted = create_run_backed_turn(conversation: conversation, acting_user: @human, answering_user: @creator).run
    standalone = standalone_run
    hidden = hosted_run(title: "Unshared Agent answer", access_default: "none")
    unrelated = Run.create!(workspace: @workspace, creating_user: @human, status: "running", approval_mode: "bypass")
    query = { agent_public_id: @creator.public_id, limit: 1, order: "asc" }
    get "/agent_api/v1/runs", params: query, headers: member_headers
    assert_response :success
    assert_equal [hosted.public_id], response.parsed_body.fetch("runs").pluck("public_id")
    after = response.parsed_body.dig("pagination", "next_after")
    get "/agent_api/v1/runs", params: query.merge(after: after), headers: member_headers
    assert_equal [standalone.public_id], response.parsed_body.fetch("runs").pluck("public_id")
    get workspace_runs_path(@workspace), params: { agent_public_id: @creator.public_id, kind: "all" }
    assert_response :success
    assert_select "input[name=agent_public_id][value=?]", @creator.public_id
    [hosted, standalone].each { |run| assert_select "article[data-run-id='#{run.public_id}']", 1 }
    [hidden, unrelated].each { |run| assert_select "article[data-run-id='#{run.public_id}']", 0 }
  end

  test "invalid date filters offer a working reset in the same workspace" do
    get workspace_runs_path(@workspace), params: { from: "2026-10-19T00:00", to: "2026-10-18T00:00" }
    assert_response :bad_request
    assert_select "a[href=?]", workspace_runs_path(@workspace), text: "Reset filters"
    assert_select "a", text: "Try again", count: 0
    assert_select "details:not([open])", text: /Technical details.*parameter_invalid/m
    assert_select "nav[aria-label=Back] a[href=?]", workspace_path(@workspace)
    get workspace_runs_path(@workspace)
    assert_response :success

    get attention_path, params: { workspace_public_id: @workspace.public_id, view: "unknown" }
    assert_response :bad_request
    reset = attention_path(workspace_public_id: @workspace.public_id)
    assert_select "a[href=?]", reset, text: "Reset filters"
    get reset
    assert_response :success
  end

  test "executor association uses retained targets and current claimants without duplicate runs or ACL expansion" do
    executor_id = SecureRandom.uuid_v7
    replacement_id = SecureRandom.uuid_v7
    targeted = standalone_run
    claimed = standalone_run
    hidden = hosted_run(title: "Private target", access_default: "none")
    [targeted, hidden].each do |run|
      2.times { |index| tool_task(run, "target#{index}", target_executor_public_id: executor_id) }
    end
    task = tool_task(claimed, "pooled", on_failure: "halt")
    task.update_columns(status: "failed", claimed_by_executor_public_id: executor_id)
    get "/agent_api/v1/runs", headers: member_headers, params: { executor_public_id: executor_id }
    assert_response :success
    assert_equal [targeted.public_id, claimed.public_id].sort, response.parsed_body.fetch("runs").pluck("public_id").sort
    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(run: claimed, task_key: task.node_key, acting_user: @human))
    assert_predicate result, :accepted?
    get "/agent_api/v1/runs", headers: member_headers, params: { executor_public_id: executor_id }
    assert_equal [targeted.public_id], response.parsed_body.fetch("runs").pluck("public_id")
    task.reload.update_columns(claimed_by_executor_public_id: replacement_id)
    get workspace_runs_path(@workspace), params: { executor_public_id: replacement_id }
    assert_response :success
    assert_select "article[data-run-id='#{claimed.public_id}']", 1
    assert_select "article[data-run-id='#{hidden.public_id}']", 0
    assert_select "input[name=executor_public_id][value=?]", replacement_id
  end

  test "attention separates read standing from actionable and excludes private authored waits" do
    full = hosted_run(title: "Writable")
    read = hosted_run(title: "Read only", access_default: "read")
    hidden = hosted_run(title: "Concealed", access_default: "none")
    [full, read, hidden].each { |run| ask_task(run, "question") }
    token = SecureRandom.uuid
    tokened = ask_task(full, "private", token: token)
    get attention_path
    assert_response :success
    assert_select "article[data-run-id='#{full.public_id}'][data-task-key='question']", 1
    assert_select "article[data-run-id='#{read.public_id}']", 0
    assert_select "article[data-task-key='#{tokened.node_key}']", 0
    assert_no_match token, response.body
    get attention_path, params: { view: "following" }
    assert_response :success
    assert_select "article[data-run-id='#{read.public_id}']", 1
    assert_select "article[data-run-id='#{hidden.public_id}']", 0
  end

  test "attention cursor pages repeated task keys across runs without internal identifiers" do
    first = standalone_run
    second = standalone_run
    [first, second].each { |run| ask_task(run, "question") }
    get "/agent_api/v1/attention", params: { limit: 1 }, headers: member_headers
    assert_response :success
    first_page = response.parsed_body
    assert_equal first.public_id, first_page.fetch("items").sole.fetch("run_public_id")
    after = first_page.dig("pagination", "next_after")
    assert after
    cursor = JSON.parse(Base64.urlsafe_decode64(after))
    assert_equal first.public_id, cursor.fetch("run_public_id")
    assert_equal "question", cursor.fetch("node_key")
    get "/agent_api/v1/attention", params: { limit: 1, after: after }, headers: member_headers
    assert_response :success
    assert_equal second.public_id, response.parsed_body.fetch("items").sole.fetch("run_public_id")
    assert_nil response.parsed_body.dig("pagination", "next_after")
  end

  test "workspace overview preserves content concealment while settings keep owner management" do
    hidden = hosted_run(title: "Hidden", access_default: "none")
    get workspace_path(@workspace)
    assert_response :success
    assert_select "a[href=?]", workspace_settings_path(@workspace)
    assert_no_match hidden.public_id, response.body
    sign_out
    sign_in_as users(:owner)
    get workspace_settings_path(@workspace)
    assert_response :success
    assert_select "form[action=?]", workspace_archival_path(@workspace), 1
  end

  private

    def hosted_run(title:, access_default: "full")
      conversation = Conversation.create!(workspace: @workspace, creating_user: @creator, answering_user: @creator,
        title: title, access_default: access_default)
      create_run_backed_turn(conversation: conversation, acting_user: @creator).run
    end

    def standalone_run(workspace: @workspace)
      Run.create!(workspace: workspace, creating_user: @creator, status: "running", approval_mode: "bypass")
    end

    def ask_task(run, key, token: nil)
      task = run.tasks.create!(type: Tasks::AwaitTask.sti_name, node_key: key,
        resolution_token: token, authored_by: token ? "author" : "model")
      task.update!(status: token ? "dispatched" : "awaiting_input", started_at: Time.current,
        await_started_at: Time.current)
      task
    end

    def member_headers
      @member_headers ||= { "Authorization" => "Bearer #{create_access_token_fixture(user: @human, name: "work-listings").secret}" }
    end

    def tool_task(run, key, **attributes)
      run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: key,
        authored_by: "author", tool_name: "read", tool_input: {}, **attributes)
    end
end
