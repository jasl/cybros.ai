require "support/runner_loop_fixtures"

class RunnerAdmissionTest < Minitest::Test
  include RunnerLoopFixtures

  def rule(name = "desktop", limit = 1)
    Rho::Env::Admission::Rule.new(resource: name, limit: limit)
  end

  def test_shared_resource_limit_is_independent_of_startup_capacity_and_other_resources
    pool = Rho::Env::Pool.new(worker_threads: 4)
    tickets = [pool.reserve(rule("desktop", 2)), pool.reserve(rule("desktop", 2))]
    assert tickets.all?
    assert_nil pool.reserve(rule("desktop", 2))
    tickets << pool.reserve(rule("browser"))
    tickets << pool.reserve
    assert tickets.all?, "other resources and ordinary tools retain their own capacity"
  ensure
    tickets&.each { |ticket| pool.release(ticket) }
    pool&.stop
  end

  def test_waiting_handler_keeps_its_resource_until_actual_exit
    pool = Rho::Env::Pool.new(worker_threads: 2)
    entered = Thread::Queue.new
    release = Thread::Queue.new
    caller = Thread.new do
      pool.run(pool.reserve(rule), Rho::Env::ExecutionContext.new) do
        entered << true
        release.pop
      end
    end
    assert entered.pop(timeout: 1)
    assert_nil pool.reserve(rule), "yielding only returns startup capacity"
    ordinary = pool.reserve
    refute_nil ordinary
    pool.release(ordinary)
    release << true
    caller.join(1)
    held = pool.reserve(rule)
    refute_nil held
  ensure
    release << true if release
    caller&.join(1)
    pool&.release(held)
    pool&.stop
  end

  def test_a_timed_out_native_handler_retains_its_resource_across_pool_replacement
    admission = Rho::Env::Admission.new
    pool = Rho::Env::Pool.new(worker_threads: 1, grace_seconds: 0.01, admission: admission)
    release = Thread::Queue.new
    entered = Thread::Queue.new
    context = Rho::Env::ExecutionContext.new(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05)
    caller = Thread.new do
      assert_raises(Rho::Env::ExecutionContext::Cancelled) do
        pool.run(pool.reserve(rule), context) do
          entered << true
          Fiber.blocking { release.pop }
        end
      end
    end
    assert entered.pop(timeout: 1)
    assert caller.join(1)
    pool.stop
    replacement = Rho::Env::Pool.new(worker_threads: 1, admission: admission)
    assert_nil replacement.reserve(rule), "a replacement must not overlap the abandoned handler"
    release << true
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep(0.001) until (held = replacement.reserve(rule)) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    refute_nil held
  ensure
    release << true if release
    caller&.join(1)
    replacement&.release(held)
    replacement&.stop
    pool&.stop
  end

  def test_busy_resource_is_not_claimed_and_unrelated_tool_can_execute
    pool = Rho::Env::Pool.new(worker_threads: 2)
    held = pool.reserve(rule)
    echo = toolset.fetch("echo")
    tools = Rho::Env::Toolset.new("echo" => echo.with(admission: rule), "files" => echo.with(name: "files"))
    lane = Lane.new(rows: [row("desktop"), row("files", tool: "files")])
    subject = Rho::Env::Executor.new(executor: lane, toolsets: fixed(tools), pool: pool, log: Silent.new)
    assert_equal :busy, subject.nudged(run_public_id: "loop-1", task_key: "desktop", tool_name: "echo")
    assert_empty lane.claims
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "files", tool_name: "files")
    assert_equal ["files"], lane.claims
  ensure
    pool&.release(held)
    subject&.stop
  end

  def test_changed_resource_hint_does_not_execute_without_a_permit
    executed = false
    tools = Rho::Env::Toolset.new("echo" => toolset { executed = true }.fetch("echo").with(admission: rule))
    lane = Lane.new(rows: [row("t1")])
    subject = runner(lane, tools)
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "stale")
    refute executed
    assert_equal "failed", lane.commits.first.fetch(:outcome)
  ensure
    subject&.stop
  end

  def test_resource_stays_held_through_result_hooks
    entered = Thread::Queue.new
    release = Thread::Queue.new
    pool = Rho::Env::Pool.new(worker_threads: 2)
    tools = Rho::Env::Toolset.new("echo" => toolset.fetch("echo").with(admission: rule))
    hook = Rho::Env::Extensions::Hooks::Registration.new(event: :tool_result, extension: "cleanup",
      handler: ->(_name, result, _tool) { entered << true; release.pop; result })
    lane = Lane.new(rows: [row("t1")])
    subject = Rho::Env::Executor.new(executor: lane, toolsets: fixed(tools), pool: pool, log: Silent.new,
      hooks: Rho::Env::Extensions::Hooks::Host.new([hook]))
    caller = Thread.new { subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "echo") }
    assert entered.pop(timeout: 1)
    assert_nil pool.reserve(rule), "the handler returned but its result hook still owns the resource"
    release << true
    assert caller.join(1)
    ticket = pool.reserve(rule)
    refute_nil ticket
  ensure
    release << true if release
    caller&.join(1)
    pool&.release(ticket)
    subject&.stop
  end

  class ChangedPlacement < Rho::Env::Toolsets::Fixed
    attr_accessor :replacement
    def for(_task) = zero.with(toolset: replacement)
  end

  def test_placement_reconfiguration_cannot_execute_under_the_previous_resource_permit
    executed = false
    old = toolset { executed = true }.fetch("echo").with(admission: rule("old"))
    placements = ChangedPlacement.new(fixed(Rho::Env::Toolset.new("echo" => old)).zero)
    placements.replacement = Rho::Env::Toolset.new("echo" => old.with(admission: rule("new")))
    lane = Lane.new(rows: [row("t1")])
    subject = Rho::Env::Executor.new(executor: lane, toolsets: placements, log: Silent.new)
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    refute executed
    assert_equal "failed", lane.commits.first.fetch(:outcome)
  ensure
    subject&.stop
  end

  def test_shutdown_releases_a_queued_resource_without_starting_its_handler
    admission = Rho::Env::Admission.new
    pool = Rho::Env::Pool.new(worker_threads: 1, grace_seconds: 0.01, admission: admission)
    yielded = Thread::Queue.new
    block_native = Thread::Queue.new
    blocked = Thread::Queue.new
    release = Thread::Queue.new
    first = Thread.new do
      assert_raises(Rho::Env::ExecutionContext::Cancelled) do
        pool.run(pool.reserve, Rho::Env::ExecutionContext.new) do
          yielded << true
          block_native.pop
          Fiber.blocking { blocked << true; release.pop }
          Rho::Env::ExecutionContext.current.raise_if_cancelled!
        end
      end
    end
    assert yielded.pop(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep(0.001) until (ticket = pool.reserve(rule)) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    refute_nil ticket
    block_native << true
    assert blocked.pop(timeout: 1)
    second = Thread.new do
      assert_raises(Rho::Env::ExecutionContext::Cancelled) do
        pool.run(ticket, Rho::Env::ExecutionContext.new) { flunk "a canceled queued task executed" }
      end
    end
    sleep(0.001) until pool.in_flight == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal 2, pool.in_flight
    pool.stop
    assert second.join(1)
    replacement = Rho::Env::Pool.new(worker_threads: 1, admission: admission)
    available = replacement.reserve(rule)
    refute_nil available, "an unstarted canceled task must not block a replacement pool"
  ensure
    block_native << true if block_native
    release << true if release
    first&.join(1)
    second&.join(1)
    replacement&.release(available)
    replacement&.stop
    pool&.stop
  end

  class RecoveringLane < Lane
    def record_list(after:)
      super.with(items: @rows.reject { |task| claims.include?(task.task_key) })
    end
  end

  def test_capacity_release_wakes_recovery_without_another_nudge
    entered = Thread::Queue.new
    release = Thread::Queue.new
    committed = Thread::Queue.new
    lane = RecoveringLane.new(rows: [row("first"), row("second")], on_commit: ->(fields) { committed << fields })
    tools = toolset do |_args, context|
      if context.task_key == "first"
        entered << true
        Fiber.blocking { release.pop }
      end
      Rho::Env::Result.ok("done")
    end
    pool = Rho::Env::Pool.new(worker_threads: 1)
    subject = Rho::Env::Executor.new(executor: lane, toolsets: fixed(tools), pool: pool, log: Silent.new)
    Async do |scope|
      follower = scope.async { subject.follow }
      scope.with_timeout(1) do
        entered.pop
        assert_equal ["first"], lane.claims, "the second row waits without a claim"
        release << true
        2.times { committed.pop }
      end
      assert_operator lane.lists, :>=, 2
      assert_equal ["first", "second"], lane.claims
    ensure
      subject.stop
      follower&.stop
    end.wait
  ensure
    release << true if release
    subject&.stop
  end
end
