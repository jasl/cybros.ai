require "support/runner_loop_fixtures"

class RoleDispatchTest < Minitest::Test
  include RunnerLoopFixtures

  def test_one_inbox_dispatches_same_named_tools_and_hooks_by_the_claimed_role
    application = row("application").with(addressed_to: CybrosAgent::Api::AddressedTo.new(
      role: "agent", executor_public_id: "ex-1"))
    lane = Lane.new(rows: [application, row("environment")])
    roles = %w[agent runner].to_h do |role|
      tools = fixed(toolset { |_args, _context| Rho::Runner::Result.ok(role) })
      [role, Rho::Runner::Service.new(toolsets: tools, hooks: Rho::Runner::Extensions::Hooks::Host.new)]
    end
    subject = Rho::Runner.new(executor: lane, toolsets: roles.fetch("runner").toolsets,
      roles: roles, log: Silent.new)
    assert_equal :busy, subject.nudged(run_public_id: "loop-1", task_key: "application", tool_name: "echo")
    assert_empty lane.claims, "without a role, wait for the authoritative inbox before reserving a tool resource"
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "application", tool_name: "echo", role: "agent")
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "environment", tool_name: "echo", role: "runner")
    assert_equal %w[agent runner], lane.commits.map { |commit| commit.fetch(:content) }
  ensure
    subject&.stop
  end

  def test_application_call_waits_for_runner_child_on_the_same_single_worker_pool
    application = row("parent", timeout_ms: 2000).with(addressed_to: CybrosAgent::Api::AddressedTo.new(
      role: "agent", executor_public_id: "ex-1"))
    lane = Lane.new(rows: [application, row("child", timeout_ms: 2000)])
    waiting = Thread::Queue.new
    answer = Thread::Queue.new
    application_tools = fixed(toolset do |_args, context|
      waiting << true
      result = nil
      until result
        context.raise_if_cancelled!
        result = answer.pop(timeout: 0.01)
      end
      Rho::Runner::Result.ok("parent received #{result}")
    end)
    runner_tools = fixed(toolset do |_args, _context|
      answer << "child result"
      Rho::Runner::Result.ok("runner child")
    end)
    roles = { "agent" => application_tools, "runner" => runner_tools }.transform_values do |tools|
      Rho::Runner::Service.new(toolsets: tools, hooks: Rho::Runner::Extensions::Hooks::Host.new)
    end
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    subject = Rho::Runner.new(executor: lane, toolsets: runner_tools, roles: roles, pool: pool, log: Silent.new)

    Async do |reactor|
      parent = reactor.async do
        subject.nudged(run_public_id: "loop-1", task_key: "parent", tool_name: "echo", role: "agent")
      end
      assert waiting.pop(timeout: 1), "the application handler must start before its child"
      assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "child", tool_name: "echo", role: "runner")
      assert_equal :done, parent.wait
    end.wait

    assert_equal ["parent received child result", "runner child"], lane.commits.map { |commit| commit.fetch(:content) }.sort
    assert lane.commits.all? { |commit| commit.fetch(:outcome) == "completed" }
  ensure
    subject&.stop
  end
end
