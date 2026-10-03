require "test_helper"

# GET /agent_api/v1/executor/inbox — THIS credential's inbox on the executor plane: the rows the
# kernel addressed to the executor the credential names, across every workspace, level-triggered and
# complete. The credential IS the standing; a member bearer is fenced at 401.
class AgentAPI::V1::Executors::InboxTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: @human, name: "Member")
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  def start!(agent_loop)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  test "a transport bearer lists the rows addressed to it, with an opaque cursor" do
    agent_loop = start!(seed(parallel(tool("alpha"), tool("beta")), tool("gamma")))

    get agent_api_v1_executor_inbox_path, headers: runner_bearer, params: { limit: 1 }
    assert_response :success
    row = response.parsed_body.fetch("tasks").sole
    assert_equal "alpha", row.fetch("task_key")
    assert_equal agent_loop.public_id, row.fetch("agent_loop_public_id")
    assert_equal @workspace.public_id, row.fetch("workspace_public_id")
    assert_equal "tool_call", row.fetch("kind")
    assert_equal({ "role" => "runner", "executor_public_id" => suite_runner.public_id }, row.fetch("addressed_to"))
    assert_equal false, row.fetch("claimed")
    assert_equal({ "path" => "alpha" }, row.fetch("tool_input"))
    cursor = response.parsed_body.dig("pagination", "next_after")
    assert_kind_of Integer, AgentLoopNode::InboxCursor.decode(cursor), "opaque, and ours to read back"
    assert_no_match(/\A\d+\z/, cursor, "the cursor never renders an id")

    get agent_api_v1_executor_inbox_path, headers: runner_bearer, params: { limit: 1, after: cursor }
    assert_response :success
    assert_equal ["beta"], response.parsed_body.fetch("tasks").map { |task| task["task_key"] }
  end

  test "a member bearer is fenced from the executor plane" do
    get agent_api_v1_executor_inbox_path, headers: bearer(@member.secret)
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "a second runner's inbox is empty of the first's row" do
    start!(seed(tool("alpha")))
    second = connect_runner(manager: users(:owner), runner_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide)

    get agent_api_v1_executor_inbox_path, headers: bearer(second.executor_access_secret)
    assert_response :success
    assert_equal [], response.parsed_body.fetch("tasks")
  end

  # The per-executor view: the workspace is not a scope here.
  test "a row in another workspace of the account addressed to this runner is listed" do
    start!(seed(tool("alpha")))
    other = Workspace.create!(account: @account, creator: users(:owner), owner: users(:owner),
      name: "Second", access_mode: "account_wide")
    start!(seed(tool("beta"), workspace: other))

    get agent_api_v1_executor_inbox_path, headers: runner_bearer
    assert_response :success
    tasks = response.parsed_body.fetch("tasks")
    assert_equal %w[alpha beta], tasks.map { |task| task.fetch("task_key") }
    assert_equal [@workspace.public_id, other.public_id], tasks.map { |task| task.fetch("workspace_public_id") }
  end

  # An ask on the wire: the question and no tool fields, never claimed, addressed to the agent
  # application — byte-pinned so the SDK's row and rho's `status` read exactly this. Authored with
  # the budget a model's `ask` carries (`Asks::Run::TIMEOUT_MS`), the row this one stands for.
  test "an ask row lists on its addressee's inbox with its question and no tool fields" do
    agent_loop = seed(ask("q", "prompt" => "which database?", "timeout_ms" => AgentLoops::Asks::Run::TIMEOUT_MS),
      creating_user: users(:agent))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: users(:agent)))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    address = task_executors(:address)
    AgentLoopNode.where(id: agent_loop.agent_loop_nodes.sole.id).update_all(
      resolution_token: nil, status: "awaiting_input",
      addressed_executor_id: address.id, addressed_role: "agent_application"
    )
    transport = create_bound_credential(executor: address, name: "Transport")

    get agent_api_v1_executor_inbox_path, headers: bearer(transport.secret)
    assert_response :success
    row = response.parsed_body.fetch("tasks").sole
    assert_equal "ask", row.fetch("kind")
    assert_equal "which database?", row.fetch("prompt")
    assert_equal "q", row.fetch("task_key")
    assert_equal agent_loop.public_id, row.fetch("agent_loop_public_id")
    assert_equal @workspace.public_id, row.fetch("workspace_public_id")
    assert_equal false, row.fetch("claimed")
    assert_equal({ "role" => "agent_application", "executor_public_id" => address.public_id },
      row.fetch("addressed_to"))
    assert_not_nil row.fetch("deadline_at")
    assert_equal AgentLoopNodes::AwaitTask::MAX_HOLD_MS, row.fetch("timeout_ms"), "the ask's own budget, one park's ceiling"
    assert_equal [], row.keys & %w[tool_name tool_input tool_call_id], "an ask names no tool"
    assert_equal [], row.keys - %w[kind agent_loop_public_id workspace_public_id conversation_public_id parent_public_id task_key prompt
                                   started_at deadline_at timeout_ms claimed addressed_to]
  end

  # Present-but-malformed is the family's 400, on every plane alike.
  test "a malformed cursor is 400 parameter_invalid" do
    get agent_api_v1_executor_inbox_path, headers: runner_bearer, params: { after: "not-a-cursor" }
    assert_response :bad_request
    assert_equal "parameter_invalid", response.parsed_body.dig("error", "code")
  end

  # The pool's eligibility conjunct reads credential readiness, which is not
  # SQL: it is computed ONCE for the executor, never once per pool row (the
  # regex is unique to the batch projection's access-token query).
  test "a paged pool inbox reads the executor's credential readiness once" do
    connection = connect_runner(manager: users(:owner), runner_identifier: "pool-a", display_name: "Provider pool-a",
      assignment_scope: :account_wide, executor_kind: :tools_provider)
    provider = connection.executor_access_token.task_executor
    assert_predicate provider.announce(tools: [{ "name" => "net_fetch", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }]), :accepted?
    2.times do |loop_index|
      start!(seed(parallel(*25.times.map { |i| tool("f#{loop_index}-#{i}", "net_fetch") }), tool("after-#{loop_index}")))
    end

    assert_queries_match(/access_tokens\.credential_epoch = task_executors\.credential_epoch/, count: 1) do
      get agent_api_v1_executor_inbox_path, headers: bearer(connection.executor_access_secret), params: { limit: 50 }
    end
    assert_response :success
    assert_equal 50, response.parsed_body.fetch("tasks").length
  end
end
