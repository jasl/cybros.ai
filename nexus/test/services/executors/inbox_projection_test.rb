require "test_helper"

# Task metadata is the executable row shared by inbox and claim, independent of
# tool-specific scope stamps or the executor consumer's selected workspace.
class Executors::InboxProjectionTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, name = "read_file", **over) = super(key, name, "input" => { "path" => key }, **over)

  test "parked tool work is always fetchable, with what a runner needs to run it" do
    agent_loop = seed(parallel(tool("alpha"), tool("beta")), tool("gamma"))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)

    tasks = Executors::Inbox.call(executor: suite_runner).tasks
    assert_equal %w[alpha beta], tasks.map { |t| t[:task_key] }
    row = tasks.first
    assert_equal agent_loop.public_id, row.fetch(:agent_loop_public_id)
    assert_equal @workspace.public_id, row.fetch(:workspace_public_id)
    assert_equal "read_file", row.fetch(:tool_name)
    assert_equal({ "path" => "alpha" }, row.fetch(:tool_input))
    assert_not_nil row.fetch(:deadline_at), "a runner must know its clock"
    assert_equal "tool_call", row.fetch(:kind)
    assert_equal({ role: "runner", executor_public_id: suite_runner.public_id }, row.fetch(:addressed_to))
    assert_equal false, row.fetch(:claimed)
    assert row.key?(:conversation_public_id), "the row says whose conversation it is"
    assert_nil row.fetch(:conversation_public_id), "an explicit null for a standalone loop"
    assert row.key?(:parent_public_id), "and whose parent's — the same kind of fact, on every row"
    assert_nil row.fetch(:parent_public_id), "an explicit null for a standalone loop"
    assert_equal [], row.keys - %i[kind agent_loop_public_id workspace_public_id conversation_public_id parent_public_id task_key tool_name
                                   tool_input tool_call_id started_at deadline_at timeout_ms
                                   claimed addressed_to],
      "no node id, no edge, no countdown, no effect profile - the cardinal " \
        "rule holds at the runner boundary too"
    refute row.key?(:scope), "the kernel's scope stamp rides an overridden kernel row only"
  end

  test "projecting a page loads workspaces once across distinct loops" do
    %w[alpha beta].each do |key|
      agent_loop = seed(tool(key))
      AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    end

    assert_queries_match(/FROM "workspaces"/, count: 1) do
      rows = Executors::Inbox.call(executor: suite_runner).tasks
      assert_equal [@workspace.public_id, @workspace.public_id],
        rows.map { |row| row.fetch(:workspace_public_id) }
    end
  end
end
