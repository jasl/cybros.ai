require "test_helper"

# The row's own answers for the inbox: the kind is derived from class AND status, the addressee is
# validated on the row, and the deadline is one derivation over three sources.
class TaskTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "inbox_kind is the subclass's answer from its own status" do
    assert_equal "tool_call", Tasks::ToolTask.new(status: "dispatched").inbox_kind
    assert_equal "approval", Tasks::ToolTask.new(status: "needs_approval").inbox_kind
    assert_nil Tasks::ToolTask.new(status: "running").inbox_kind, "a kernel job is nobody's row"
    assert_nil Tasks::ToolTask.new(status: "completed").inbox_kind

    assert_equal "ask", Tasks::AwaitTask.new(status: "awaiting_input").inbox_kind
    assert_nil Tasks::AwaitTask.new(status: "dispatched").inbox_kind,
      "a tokened await is a holder's, never an inbox row"

    assert_nil Tasks::ModelTask.new(status: "running").inbox_kind
    assert_nil Tasks::ModelTask.new(status: "queued").inbox_kind, "a round has no stage and no inbox word"
    assert_nil Tasks::JoinTask.new(status: "queued").inbox_kind
  end

  test "approval names use captured routes while Nexus MCP and kernel aliases keep their own selectors" do
    runner = Tasks::ToolTask.new(tool_name: "read_file", tool_alias: "remote_read",
      target_executor_public_id: SecureRandom.uuid_v7)
    assert_equal %w[read_file remote_read], runner.approval_names
    runner.tool_alias = "read_file"
    assert_equal ["read_file"], runner.approval_names

    mcp = Tasks::ToolTask.new(tool_name: "search", tool_alias: "work_search",
      mcp_connection_public_id: SecureRandom.uuid_v7)
    assert_equal ["work_search"], mcp.approval_names
    kernel = Tasks::ToolTask.new(tool_name: "memory_read", tool_alias: "Recall")
    assert_equal ["memory_read"], kernel.approval_names
  end

  test "a runner- or agent-addressed row names its executor; a tool_provider row may be a pool" do
    node = seed(tool("alpha")).tasks.find_by!(node_key: "alpha")
    # An address is a STARTED row's fact (a queued one names nobody), so
    # the row is put where an address belongs — past the machine, which
    # only lets it there through the stage — before the rule is read.
    Task.where(id: node.id).update_all(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
    node.reload

    node.addressed_role = "runner"
    assert_not node.valid?
    assert node.errors.of_kind?(:addressed_executor, :blank)

    node.addressed_role = "agent"
    assert_not node.valid?

    node.addressed_role = "tool_provider"
    assert_predicate node, :valid?, "a pool row names a role and no executor"

    node.addressed_role = "runner"
    node.addressed_executor = executors(:address)
    assert_predicate node, :valid?

    node.addressed_role = "somebody"
    assert_not node.valid?
    assert node.errors.of_kind?(:addressed_role, :inclusion)
  end

  test "effective_timeout_ms is authored, else announced, else the default" do
    authored = Tasks::ToolTask.new(timeout_ms: 5_000, effect_profile: { "timeout_ms" => 9_000 })
    assert_equal 5_000, authored.effective_timeout_ms

    announced = Tasks::ToolTask.new(timeout_ms: nil, effect_profile: { "timeout_ms" => 9_000 })
    assert_equal 9_000, announced.effective_timeout_ms

    neither = Tasks::ToolTask.new(timeout_ms: nil, effect_profile: nil)
    assert_equal Tasks::ToolTask::DEFAULT_TIMEOUT_MS, neither.effective_timeout_ms

    profiled = Tasks::ToolTask.new(timeout_ms: nil, effect_profile: Nexus::ToolRegistry::READ_ONLY_CLOSED)
    assert_equal Tasks::ToolTask::DEFAULT_TIMEOUT_MS, profiled.effective_timeout_ms,
      "a profile that announced no timeout falls to the kernel default"
  end

  # A held row's clock is the approver's: the ask's 24 h, whatever the tool's authored or announced
  # RUN clock says — that one starts at dispatch.
  test "a held row's effective timeout is MAX_HOLD whatever timeout_ms says" do
    held = Tasks::ToolTask.new(status: "needs_approval", timeout_ms: 1_000,
      effect_profile: { "timeout_ms" => 500 })
    assert_equal Tasks::AwaitTask::MAX_HOLD_MS, held.effective_timeout_ms
    armed = Time.utc(2026, 9, 8, 12, 0, 0)
    held.await_started_at = armed
    assert_equal armed + Tasks::AwaitTask::MAX_HOLD, held.deadline_at

    released = Tasks::ToolTask.new(status: "dispatched", timeout_ms: 1_000)
    assert_equal 1_000, released.effective_timeout_ms, "past the stage the run clock is the tool's"
  end

  test "a tool task carries no create-time timeout: authored none is observable" do
    node = seed(tool("alpha")).tasks.find_by!(node_key: "alpha")

    assert_nil node.timeout_ms
    assert_equal Tasks::ToolTask::DEFAULT_TIMEOUT_MS, node.effective_timeout_ms
    zero = Tasks::ToolTask.new(run: node.run, node_key: "zero", tool_name: "x", timeout_ms: 0)
    assert_not zero.valid?
    assert zero.errors.of_kind?(:timeout_ms, :greater_than)
  end
end
