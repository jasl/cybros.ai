require "test_helper"

class RunnerResourcesTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:owner)
    sign_in_as @human
  end

  test "detail separates application assignment from Human eligibility and keeps saved announcement text escaped" do
    connection = connect_combined_session(steward: @human, agent_identifier: "detail-app", registration_identifier: "detail-runner")
    runner = connection.runner.executor_access_token.executor
    assert_predicate runner.announce(
      tools: [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
        "description" => "<script>announced</script>", "input_schema" => { "type" => "object" } }],
      documents: [{ "name" => "project", "description" => "<script>document</script>" }],
      environment: { "root" => "<script>environment</script>" }
    ), :accepted?

    assert_no_enqueued_jobs { get runner_path(runner) }
    assert_response :success
    assert_select "h1", runner.display_name
    assert_select "dd[data-execution-eligible=false]", text: "Not allowed"
    assert_select "dd", text: "Ready"
    assert_select "dd", text: "Not yet seen"
    assert_select "summary", text: "read"
    assert_select "script", text: /announced|document|environment/, count: 0
    assert_select "a[href=?]", runner_runs_path(runner), text: "View 0 related runs"

    runner.revoke_credentials
    get runner_path(runner)
    assert_response :success
    assert_select "dd", text: "No credential"
    runner.revoke
    get runner_path(runner)
    assert_response :success
    assert_select "header span", text: "Revoked"
    assert_select "form[action=?]", runner_path(runner), count: 0
  end

  test "manager run counts use readable retained targets and match the filtered list" do
    runner = connect_runner(manager: @human).executor_access_token.executor
    visible = Run.create!(workspace: workspaces(:shared), creating_user: users(:agent), status: "running", approval_mode: "bypass")
    private_run = Run.create!(workspace: workspaces(:personal), creating_user: users(:curator), status: "running", approval_mode: "bypass")
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:agent),
      answering_user: users(:agent), title: "Concealed", access_default: "none")
    concealed = create_run_backed_turn(conversation: conversation, acting_user: users(:agent)).run
    [visible, private_run, concealed].each do |run|
      2.times do |index|
        run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "read#{index}", authored_by: "author",
          tool_name: "read", tool_input: {}, target_executor_public_id: runner.public_id)
      end
    end
    get runner_path(runner)
    assert_response :success
    assert_select "a[href=?]", runner_runs_path(runner), text: "View 1 related run"
    assert_select "a[href=?]", runner_runs_path(runner, status: "running"), text: "Running · 1"
    get runner_runs_path(runner)
    assert_response :success
    assert_select "article[data-run-id]", 1
    assert_select "article[data-run-id='#{visible.public_id}']", 1
    [concealed, private_run].each { |run| assert_not_includes response.body, run.public_id }
  end

  test "list links details and filters revoked tool providers and MCP links the matching management collection" do
    runner = connect_runner(manager: @human, registration_identifier: "runner").executor_access_token.executor
    provider = connect_runner(manager: @human, registration_identifier: "provider", executor_kind: :tool_provider).executor_access_token.executor
    provider.revoke
    get runners_path
    assert_response :success
    assert_select "a[href=?]", runner_path(runner), text: runner.display_name
    assert_select "a[href=?]", runner_path(provider), count: 0
    get runners_path, params: { kind: "tool_provider", status: "revoked" }
    assert_response :success
    assert_select "a[href=?]", runner_path(provider), text: provider.display_name
    assert_select "a[href=?]", runner_path(runner), count: 0
    assert_select "button", text: "Remove connection", count: 0
    get settings_mcp_connections_path
    assert_response :success
    assert_select "a[href=?][data-turbo-frame='_top']", runners_path(kind: "tool_provider")
  end

  test "a non-manager administrator has no detail authority and signed out navigation requires login" do
    runner = connect_runner(manager: users(:member)).executor_access_token.executor
    get runner_path(runner)
    assert_response :not_found
    sign_out
    get runner_path(runner)
    assert_redirected_to new_session_path(return_to: runner_path(runner))
  end
end
