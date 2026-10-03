require "test_helper"

# The row's own answers for the inbox: the kind is derived from class AND status, the addressee is
# validated on the row, and the deadline is one derivation over three sources.
class AgentLoopNodeTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "inbox_kind is the subclass's answer from its own status" do
    assert_equal "tool_call", AgentLoopNodes::ToolTask.new(status: "dispatched").inbox_kind
    assert_equal "approval", AgentLoopNodes::ToolTask.new(status: "needs_approval").inbox_kind
    assert_nil AgentLoopNodes::ToolTask.new(status: "running").inbox_kind, "a kernel job is nobody's row"
    assert_nil AgentLoopNodes::ToolTask.new(status: "completed").inbox_kind

    assert_equal "ask", AgentLoopNodes::AwaitTask.new(status: "awaiting_input").inbox_kind
    assert_nil AgentLoopNodes::AwaitTask.new(status: "dispatched").inbox_kind,
      "a tokened await is a holder's, never an inbox row"

    assert_nil AgentLoopNodes::ModelTask.new(status: "running").inbox_kind
    assert_nil AgentLoopNodes::ModelTask.new(status: "queued").inbox_kind, "a round has no stage and no inbox word"
    assert_nil AgentLoopNodes::JoinTask.new(status: "queued").inbox_kind
  end

  test "a runner- or agent-addressed row names its executor; a tools_provider row may be a pool" do
    node = seed(tool("alpha")).agent_loop_nodes.find_by!(node_key: "alpha")
    # An address is a STARTED row's fact (a queued one names nobody), so
    # the row is put where an address belongs — past the machine, which
    # only lets it there through the stage — before the rule is read.
    AgentLoopNode.where(id: node.id).update_all(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
    node.reload

    node.addressed_role = "runner"
    assert_not node.valid?
    assert node.errors.of_kind?(:addressed_executor, :blank)

    node.addressed_role = "agent_application"
    assert_not node.valid?

    node.addressed_role = "tools_provider"
    assert_predicate node, :valid?, "a pool row names a role and no executor"

    node.addressed_role = "runner"
    node.addressed_executor = task_executors(:address)
    assert_predicate node, :valid?

    node.addressed_role = "somebody"
    assert_not node.valid?
    assert node.errors.of_kind?(:addressed_role, :inclusion)
  end

  test "effective_timeout_ms is authored, else announced, else the default" do
    authored = AgentLoopNodes::ToolTask.new(timeout_ms: 5_000, effect_profile: { "timeout_ms" => 9_000 })
    assert_equal 5_000, authored.effective_timeout_ms

    announced = AgentLoopNodes::ToolTask.new(timeout_ms: nil, effect_profile: { "timeout_ms" => 9_000 })
    assert_equal 9_000, announced.effective_timeout_ms

    neither = AgentLoopNodes::ToolTask.new(timeout_ms: nil, effect_profile: nil)
    assert_equal AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS, neither.effective_timeout_ms

    profiled = AgentLoopNodes::ToolTask.new(timeout_ms: nil, effect_profile: Nexus::ToolRegistry::READ_ONLY_CLOSED)
    assert_equal AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS, profiled.effective_timeout_ms,
      "a profile that announced no timeout falls to the kernel default"
  end

  # A held row's clock is the approver's: the ask's 24 h, whatever the tool's authored or announced
  # RUN clock says — that one starts at dispatch.
  test "a held row's effective timeout is MAX_HOLD whatever timeout_ms says" do
    held = AgentLoopNodes::ToolTask.new(status: "needs_approval", timeout_ms: 1_000,
      effect_profile: { "timeout_ms" => 500 })
    assert_equal AgentLoopNodes::AwaitTask::MAX_HOLD_MS, held.effective_timeout_ms
    armed = Time.utc(2026, 9, 8, 12, 0, 0)
    held.await_started_at = armed
    assert_equal armed + AgentLoopNodes::AwaitTask::MAX_HOLD, held.deadline_at

    released = AgentLoopNodes::ToolTask.new(status: "dispatched", timeout_ms: 1_000)
    assert_equal 1_000, released.effective_timeout_ms, "past the stage the run clock is the tool's"
  end

  test "a tool task carries no create-time timeout: authored none is observable" do
    node = seed(tool("alpha")).agent_loop_nodes.find_by!(node_key: "alpha")

    assert_nil node.timeout_ms
    assert_equal AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS, node.effective_timeout_ms
    zero = AgentLoopNodes::ToolTask.new(agent_loop: node.agent_loop, node_key: "zero", tool_name: "x", timeout_ms: 0)
    assert_not zero.valid?
    assert zero.errors.of_kind?(:timeout_ms, :greater_than)
  end
end
