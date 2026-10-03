require "test_helper"

class RunnerControlFailureTest < Minitest::Test
  class Transport
    attr_reader :commits, :paths

    def initialize(park_seconds:)
      @park_seconds = park_seconds
      @commits = []
      @paths = []
    end

    def call(path, **request)
      @paths << path
      case path
      when %r{/claim\z}
        body = {
          "task" => {
            "kind" => "tool_call", "workspace_public_id" => "ws-1", "agent_loop_public_id" => "loop-1", "conversation_public_id" => nil,
            "parent_public_id" => nil, "task_key" => "t1",
            "tool_name" => "work", "tool_input" => {}, "timeout_ms" => @park_seconds * 1000, "claimed" => true,
            "addressed_to" => { "role" => "runner", "executor_public_id" => "runner-1" },
          },
          "claim" => { "claim_token" => "claim-1", "deadline_at" => (Time.now + @park_seconds).iso8601(3) },
        }
      when %r{/commit\z}
        @commits << request.fetch(:body)
        body = { "task" => { "status" => "completed" } }
      else
        raise "unexpected request: #{path}"
      end
      CybrosAgent::Response.new(status: 200, headers: {}, body: body)
    end
  end

  class Log
    attr_reader :warnings

    def initialize = @warnings = []
    def info(*, **) = nil
    def warn(event, **fields) = @warnings << [event, fields]
  end

  def test_a_progress_credential_refresh_refusal_does_not_release_a_running_handler
    error = CybrosAgent::DeviceFlow::RateLimited.new(retry_after: 1)
    assert_control_refusal(error, progress: true, park_seconds: 60,
      expected_event: "runner_progress_refused")
  end

  def test_an_extension_credential_persistence_failure_keeps_the_handler_under_its_original_deadline
    error = CybrosAgent::Credentials::NotDurable.new("the rotated credential could not be saved")
    assert_control_refusal(error, progress: false, park_seconds: 2,
      expected_event: "runner_extension_refused")
  end

  private

    # The same provider a long-lived executor client receives from its OAuth
    # owner. Claim succeeds; the next request's credential read fails once,
    # before any request bytes are sent; the live credential remains usable
    # for the later commit. The worker waits through that control-plane error.
    def assert_control_refusal(error, progress:, park_seconds:, expected_event:)
      reads = 0
      refused = Queue.new
      provider = lambda do
        reads += 1
        if reads == 2
          refused << true
          raise error
        end
        "executor-token"
      end
      transport = Transport.new(park_seconds: park_seconds)
      executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: transport,
        credential_provider: provider)
      entered = Queue.new
      release = Queue.new
      tool = Rho::Runner::Toolset::Tool.new(name: "work", description: "work",
        parameters: { "type" => "object" }, handler: lambda { |_input, context|
          entered << context
          context.report_progress("working") if progress
          release.pop
          context.raise_if_cancelled!
          Rho::Runner::Result.ok("effect completed")
        })
      tools = Rho::Runner::Toolsets.fixed(toolset: Rho::Runner::Toolset.new("work" => tool))
      pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
      log = Log.new
      runner = Rho::Runner.new(executor: executor, toolsets: tools, log: log, pool: pool)
      caller = Thread.new { runner.nudged(agent_loop_public_id: "loop-1", task_key: "t1") }
      context = entered.pop(timeout: 2)
      refute_nil context, "the claimed handler must start"
      original_deadline = context.deadline
      assert refused.pop(timeout: 3), "the control request must consult the credential owner"

      assert_nil caller.join(0.05), "a credential-read error must not answer for a still-running handler"
      assert_equal 1, pool.in_flight
      assert_nil pool.reserve, "the active handler must retain its one admission ticket"
      refute context.cancelled?, "the original task deadline still stands"
      assert_equal original_deadline, context.deadline
      assert_empty transport.commits, "no failed result may precede the tool's actual effect"

      release << true
      assert caller.join(2), "the handler's real result should be delivered"
      assert_equal 1, transport.commits.length
      assert_equal "completed", transport.commits.first.fetch("outcome")
      assert_equal "effect completed", transport.commits.first.fetch("content")
      assert_equal 0, pool.in_flight
      assert_equal 3, reads, "only claim, the refused control request, and commit read credentials"
      assert_equal [expected_event], log.warnings.map(&:first)
      assert_equal error.class.name, log.warnings.first.last.fetch(:code)
    ensure
      release << true if release
      caller&.join(2)
      runner&.stop(answer_wait: 0.0)
    end
end
