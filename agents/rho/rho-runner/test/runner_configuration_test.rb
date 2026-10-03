require "support/runner_loop_fixtures"

class RunnerConfigurationTest < Minitest::Test
  include RunnerLoopFixtures

  def test_configuring_hooks_keeps_an_active_calls_pair_and_changes_the_next_call
    entered = Queue.new
    release = Queue.new
    seen = []
    lane = Lane.new(rows: [row("t1"), row("t2")])
    tools = toolset do |args, context|
      if context.task_key == "t1"
        entered << true
        release.pop
      end
      Rho::Runner::Result.ok(args.fetch("text"))
    end
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil }, hooks: hooks("old", seen))
    worker = Thread.new { subject.nudged(agent_loop_public_id: "loop-1", task_key: "t1") }

    assert entered.pop(timeout: 5), "the first tool did not start"
    subject.configure(hooks: hooks("new", seen))
    release << true
    assert worker.join(5), "the active call did not finish"
    assert_equal :done, worker.value
    assert_equal :done, subject.nudged(agent_loop_public_id: "loop-1", task_key: "t2")

    assert_equal [["old", :before, "t1"], ["old", :after, "t1"],
                  ["new", :before, "t2"], ["new", :after, "t2"]], seen
    assert_equal %w[completed completed], lane.commits.map { |commit| commit.fetch(:outcome) }
    assert_equal ["old:old", "new:new"], lane.commits.map { |commit| commit.fetch(:content) }
  ensure
    release << true
    worker&.join(5)
    subject&.stop
  end

  private

    def hooks(label, seen)
      registrations = [
        Rho::Runner::Extensions::Hooks::Registration.new(event: :tool_call, extension: label,
          handler: lambda { |_name, arguments, _tool|
            seen << [label, :before, Rho::Runner::ExecutionContext.current.task_key]
            Rho::Runner::Extensions::Hooks::Rewrite.new(arguments: arguments.merge("text" => label))
          }),
        Rho::Runner::Extensions::Hooks::Registration.new(event: :tool_result, extension: label,
          handler: lambda { |_name, result, _tool|
            seen << [label, :after, Rho::Runner::ExecutionContext.current.task_key]
            Rho::Runner::Result.ok("#{label}:#{result.content}")
          }),
      ]
      Rho::Runner::Extensions::Hooks::Host.new(registrations)
    end
end
