require "support/runner_loop_fixtures"

class RunnerConfigurationTest < Minitest::Test
  include RunnerLoopFixtures

  def test_configuring_hooks_keeps_an_active_calls_pair_and_changes_the_next_call
    entered = Queue.new
    release = Queue.new
    seen = []
    closed = []
    owner = Rho::Runner::Extensions::Resources.new(extension: "old")
    owner.own { closed << :old }
    lane = Lane.new(rows: [row("t1"), row("t2")])
    tools = toolset do |args, context|
      if context.task_key == "t1"
        entered << true
        release.pop
      end
      Rho::Runner::Result.ok(args.fetch("text"))
    end
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil }, hooks: hooks("old", seen, owner: owner))
    worker = Thread.new { subject.nudged(run_public_id: "loop-1", task_key: "t1") }

    assert entered.pop(timeout: 5), "the first tool did not start"
    subject.configure(hooks: hooks("new", seen))
    refute owner.retire
    assert_empty closed
    release << true
    assert worker.join(5), "the active call did not finish"
    assert_equal :done, worker.value
    assert_equal [:old], closed
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t2")

    assert_equal [["old", :before, "t1"], ["old", :after, "t1"],
                  ["new", :before, "t2"], ["new", :after, "t2"]], seen
    assert_equal %w[completed completed], lane.commits.map { |commit| commit.fetch(:outcome) }
    assert_equal ["old:old", "new:new"], lane.commits.map { |commit| commit.fetch(:content) }
  ensure
    release << true
    worker&.join(5)
    subject&.stop
  end

  def test_a_timed_out_abandoned_handler_keeps_its_retired_resources_until_it_finishes
    entered = Queue.new
    release = Queue.new
    closed = Queue.new
    owner = Rho::Runner::Extensions::Resources.new(extension: "slow")
    owner.own { closed << :connection }
    lane = Lane.new(rows: [row("t1", timeout_ms: 100)], deadline_at: -> { (Time.now + 0.1).iso8601(3) })
    tools = toolset(internal_clamp: true) do |_args, _context|
      entered << true
      release.pop
      Rho::Runner::Result.ok("late")
    end
    tools = Rho::Runner::Toolset.new("echo" => tools.fetch("echo").with(owner: owner))
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.01), sleeper: ->(_) { nil })
    caller = Thread.new { subject.nudged(run_public_id: "loop-1", task_key: "t1") }
    assert entered.pop(timeout: 2), "the handler never started"
    refute owner.retire
    assert caller.join(2), "the caller never received its timeout"
    assert lane.commits.first.fetch(:is_error)
    assert_match(/timed out/, lane.commits.first.fetch(:content))

    assert closed.empty?, "the caller's timeout closed resources still used by its abandoned handler"
    release << true
    assert_equal :connection, closed.pop(timeout: 2)
    assert closed.empty?, "cleanup ran more than once"
  ensure
    release << true if release
    caller&.join(2)
    subject&.stop
  end

  private

    def hooks(label, seen, owner: nil)
      registrations = [
        Rho::Runner::Extensions::Hooks::Registration.new(event: :tool_call, extension: label, owner: owner,
          handler: lambda { |_name, arguments, _tool|
            seen << [label, :before, Rho::Runner::ExecutionContext.current.task_key]
            Rho::Runner::Extensions::Hooks::Rewrite.new(arguments: arguments.merge("text" => label))
          }),
        Rho::Runner::Extensions::Hooks::Registration.new(event: :tool_result, extension: label, owner: owner,
          handler: lambda { |_name, result, _tool|
            seen << [label, :after, Rho::Runner::ExecutionContext.current.task_key]
            Rho::Runner::Result.ok("#{label}:#{result.content}")
          }),
      ]
      Rho::Runner::Extensions::Hooks::Host.new(registrations)
    end
end
