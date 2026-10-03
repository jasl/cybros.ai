require "test_helper"

class RunnerCancellationRecoveryTest < Minitest::Test
  class Transport
    attr_reader :commits, :checks

    def initialize
      @commits = []
      @checks = []
    end

    def call(path, **request)
      body = case path
      when %r{/inbox\z}
        { "tasks" => [task], "pagination" => { "next_after" => nil } }
      when %r{/claim\z}
        if request.fetch(:method) == :get
          @checks << request
          { "claim" => { "active" => false } }
        else
          { "task" => task.merge("claimed" => true),
            "claim" => { "claim_token" => "claim-1", "deadline_at" => (Time.now + 60).iso8601(3) } }
        end
      when %r{/commit\z}
        @commits << request.fetch(:body)
        { "task" => { "status" => "failed" } }
      else
        raise "unexpected request: #{path}"
      end
      CybrosAgent::Response.new(status: 200, headers: {}, body: body)
    end

    private

      def task
        { "kind" => "tool_call", "workspace_public_id" => "ws-1", "agent_loop_public_id" => "loop-1", "conversation_public_id" => nil,
          "parent_public_id" => nil, "task_key" => "t1",
          "tool_name" => "work", "tool_input" => {}, "claimed" => false,
          "addressed_to" => { "role" => "runner", "executor_public_id" => "runner-1" } }
      end
  end

  class Log
    def info(*, **) = nil
    def warn(*, **) = nil
  end

  def test_an_http_sweep_recovers_cancellation_while_a_silent_handler_is_running
    transport = Transport.new
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: transport,
      credential_provider: -> { "executor-token" })
    entered = Queue.new
    release = Queue.new
    tool = Rho::Runner::Toolset::Tool.new(name: "work", description: "work",
      parameters: { "type" => "object" }, handler: lambda { |_input, context|
        Rho::Runner::ExecutionContext.with_cancel_signal(-> { release << true }) do
          entered << context
          release.pop
          context.raise_if_cancelled!
          Rho::Runner::Result.ok("finished")
        end
      })
    tools = Rho::Runner::Toolsets.fixed(toolset: Rho::Runner::Toolset.new("work" => tool))
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    runner = Rho::Runner.new(executor: executor, toolsets: tools, log: Log.new, pool: pool,
      sleeper: ->(_) { runner.stop(answer_wait: 0.0) })
    caller = Thread.new { runner.follow }
    context = entered.pop(timeout: 2)
    refute_nil context
    assert caller.join(7), "HTTP recovery must run inside the active handler wait, before the next inbox sweep"
    assert_equal :canceled, context.reason
    assert_equal 1, runner.snapshot.canceled
    assert_equal 0, runner.snapshot.nudged
    assert_equal 1, runner.snapshot.claimed
    assert_equal 1, transport.checks.length
    assert_equal "claim-1", transport.checks.first.fetch(:headers).fetch("Claim-Token")
    assert_equal "failed", transport.commits.fetch(0).fetch("outcome")
    assert_equal 0, pool.in_flight
  ensure
    release << true if release
    caller&.join(2)
    runner&.stop(answer_wait: 0.0)
  end
end
