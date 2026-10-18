require "test_helper"

class ScopedRunCollectionsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    @runner = connect_runner(manager: @human).executor_access_token.executor
    sign_in_as @human
  end

  test "Runner scope survives filters pagination details and reset while ignoring an alternate executor" do
    other = connect_runner(manager: @human, registration_identifier: "other").executor_access_token.executor
    first = related_run(@runner)
    second = related_run(@runner)
    unrelated = related_run(other)
    get runner_runs_path(@runner), params: { executor_public_id: other.public_id, limit: 1, order: "asc" }
    assert_response :success
    assert_select "article[data-run-id=?]", first.public_id
    assert_select "article[data-run-id=?]", unrelated.public_id, count: 0
    assert_select "input[name=executor_public_id]", count: 0
    assert_select "a[href=?]", runner_runs_path(@runner), text: "Reset"
    next_path = css_select("a").find { |link| link.text == "Next page" }["href"]
    get next_path
    assert_response :success
    assert_select "article[data-run-id=?]", second.public_id
    detail_path = css_select("article a").first["href"]
    get detail_path
    assert_response :success
    assert_select "a[href=?]", next_path
    get runner_runs_path(@runner)
    assert_select "article[data-run-id]", 2
    get runner_runs_path(@runner), params: { workspace_public_id: workspaces(:personal).public_id }
    assert_response :not_found
  end

  test "a Run can belong to several Runners through retained targets or claimants and disappears when details are removed" do
    other = connect_runner(manager: @human, registration_identifier: "other").executor_access_token.executor
    run = related_run(@runner)
    run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "second", authored_by: "author", tool_name: "read",
      tool_input: {}).update_columns(claimed_by_executor_public_id: other.public_id)
    [@runner, other].each do |runner|
      get runner_runs_path(runner)
      assert_response :success
      assert_select "article[data-run-id=?]", run.public_id
    end
    run.tasks.destroy_all
    get runner_runs_path(@runner)
    assert_select "article[data-run-id]", 0
    get runner_path(@runner)
    assert_select "a[href=?]", runner_runs_path(@runner), text: "View 0 related runs"
  end

  test "Attention runs retain their fixed reason and default to both kinds with read-only work included" do
    standalone = related_run(@runner)
    standalone.update!(attention_reason: "awaiting_human")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, answering_user: @agent,
      title: "Read-only attention", access_default: "read")
    hosted = create_run_backed_turn(conversation: conversation, acting_user: @agent).run
    hosted.update!(attention_reason: "awaiting_human")
    unrelated = related_run(@runner)
    get attention_runs_path, params: { attention: "", workspace_public_id: @workspace.public_id, limit: 1, order: "asc" }
    assert_response :success
    assert_select "article[data-run-id=?]", standalone.public_id
    assert_select "option[value=all][selected]"
    assert_select "input[name=attention]", count: 0
    assert_select "a[href=?]", attention_runs_path, text: "Reset"
    get css_select("a").find { |link| link.text == "Next page" }["href"]
    assert_select "article[data-run-id=?]", hosted.public_id
    assert_select "article[data-run-id=?]", unrelated.public_id, count: 0
    get run_path(hosted)
    assert_response :success
    assert_select "form[action=?]", run_pause_path(hosted), count: 0
    get attention_runs_path
    assert_select "article[data-run-id]", 2
    get attention_path
    assert_select "a[href=?]", attention_runs_path
  end

  test "Runner management does not follow account-wide eligibility or administrator role" do
    foreign = connect_runner(manager: users(:owner), assignment_scope: :account_wide).executor_access_token.executor
    get runner_runs_path(foreign)
    assert_response :not_found
    sign_out
    sign_in_as users(:owner)
    get runner_runs_path(@runner)
    assert_response :not_found
  end

  private

    def related_run(runner)
      run = Run.create!(workspace: @workspace, creating_user: @agent, status: "running", approval_mode: "bypass")
      run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "read", authored_by: "author", tool_name: "read",
        tool_input: {}, target_executor_public_id: runner.public_id)
      run
    end
end
