require "test_helper"

# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/claim — the executor plane's claim: granted to
# the credential's own address when the row names it, the executor is eligible for the loop's
# principal, that principal still writes, and the row is a claimable park. Every refusal is a
# reachable conflict at 409 under one code; a loop outside the executor's account is absence.
class AgentAPI::V1::Executors::ClaimsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: @human, name: "Member")
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  def start!(agent_run, acting_user: @human)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  def claim(agent_run, key, headers: runner_bearer)
    post agent_api_v1_executor_inbox_claim_path(run_public_id: agent_run.public_id, task_key: key),
      headers: headers
  end

  def assert_refused(code)
    assert_response :conflict
    assert_equal code, response.parsed_body.dig("error", "code")
  end

  test "the grant answers the executable row and a token; the same address twice is already_claimed" do
    agent_run = start!(seed(tool("alpha")))

    claim(agent_run, "alpha")
    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "alpha", task.fetch("task_key")
    assert_equal({ "path" => "alpha" }, task.fetch("tool_input"))
    assert_equal true, task.fetch("claimed")
    assert_equal "tool_call", task.fetch("kind")
    assert_equal @workspace.public_id, task.fetch("workspace_public_id")
    token = response.parsed_body.dig("claim", "claim_token")
    assert token.present?
    assert response.parsed_body.dig("claim", "deadline_at").present?
    # The budget rides the task, one home: the grant states the number the listed row states.
    get agent_api_v1_executor_inbox_path, headers: runner_bearer
    assert_equal response.parsed_body.fetch("tasks").sole.fetch("timeout_ms"), task.fetch("timeout_ms")
    assert_equal token, agent_run.agent_run_tasks.sole.reload.claim_token
    assert_equal suite_runner.id, agent_run.agent_run_tasks.sole.claimed_by_executor_id

    # Two PROCESSES of one address see the same row; the node lock decides.
    claim(agent_run, "alpha")
    assert_refused("already_claimed")
    assert_equal token, agent_run.agent_run_tasks.sole.reload.claim_token, "no rotation under a refusal"
  end

  # The two-executor race: the row names its addressee, so the other
  # address is refused before any lock — and the addressed one is granted.
  test "two executors on one row: the addressed one is granted, the other is not_addressed_here" do
    agent_run = start!(seed(tool("alpha")))
    second = connect_runner(manager: users(:owner), registration_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide)
    second.executor_access_token.task_executor.announce(tools: TEST_SERVED_TOOLS)

    claim(agent_run, "alpha", headers: bearer(second.executor_access_secret))
    assert_refused("not_addressed_here")
    assert_nil agent_run.agent_run_tasks.sole.reload.claimed_at

    claim(agent_run, "alpha")
    assert_response :success
  end

  # A kernel-executed tool is `running` in one of the kernel's own jobs and carries no addressee;
  # the row is written in that shape here (the scheduler's own path is driven in
  # Executors::InboxTest).
  test "a kernel row carries no addressee and is not_addressed_here" do
    agent_run = start!(seed(tool("k")))
    AgentRunTask.where(id: agent_run.agent_run_tasks.sole.id)
      .update_all(status: "running", addressed_executor_id: nil, addressed_role: nil)
    assert_nil agent_run.agent_run_tasks.sole.reload.inbox_kind

    claim(agent_run, "k")
    assert_refused("not_addressed_here")
  end

  # The tokenless ask the kernel's AskJob appends on an agent's loop
  # (awaits_test drives it through the model); here the row is written in
  # that shape, addressed to the declaring agent's address.
  test "an ask row is not_claimable_kind for its own addressee" do
    agent_run = start!(seed(ask("q"), creating_user: users(:agent)), acting_user: users(:agent))
    address = task_executors(:address)
    AgentRunTask.where(id: agent_run.agent_run_tasks.sole.id).update_all(
      resolution_token: nil, status: "awaiting_input",
      addressed_executor_id: address.id, addressed_role: "agent_application"
    )
    assert_equal "ask", agent_run.agent_run_tasks.sole.reload.inbox_kind
    transport = create_bound_credential(executor: address, name: "Transport")

    claim(agent_run, "q", headers: bearer(transport.secret))
    assert_refused("not_claimable_kind")
  end

  test "a revoked runner is not_eligible" do
    agent_run = start!(seed(tool("alpha")))
    suite_runner.revoke
    # A revoked executor's transport credential no longer authenticates at
    # all; the eligibility fence is what a still-usable credential meets.
    claim(agent_run, "alpha")
    assert_response :unauthorized
  end

  test "the loop's principal losing write standing is not_authorized at 409" do
    agent_run = start!(seed(tool("alpha"), creating_user: users(:agent)), acting_user: users(:agent))
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "someone-else")

    claim(agent_run, "alpha")
    assert_refused("not_authorized")
    assert_nil agent_run.agent_run_tasks.sole.reload.claimed_at
  end

  # The finder is the executor's ACCOUNT (a singleton in this deployment,
  # so a foreign loop cannot be built here): a loop it does not hold, a key
  # the loop does not hold, and a tombstoned loop all read as absence.
  test "an unknown loop, an unknown key, a tombstoned loop and a member bearer" do
    agent_run = start!(seed(tool("alpha")))

    post agent_api_v1_executor_inbox_claim_path(
      run_public_id: "01900000-0000-7000-8000-000000000099", task_key: "alpha"
    ), headers: runner_bearer
    assert_response :not_found
    claim(agent_run, "nope")
    assert_response :not_found
    tombstoned = start!(seed(tool("beta")))
    AgentRun.where(id: tombstoned.id).update_all(status: "completed", tombstoned_at: Time.current)
    claim(tombstoned, "beta")
    assert_response :not_found
    claim(agent_run, "alpha", headers: bearer(@member.secret))
    assert_response :unauthorized
  end
end
