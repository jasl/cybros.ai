require "test_helper"

class RunnerClaimStatusExecutionTest < Minitest::Test
  class Transport
    attr_accessor :read
    attr_reader :checks, :commits

    def initialize
      @checks = []
      @commits = []
      @read = -> { { "claim" => { "active" => true } } }
    end

    def call(path, **request)
      body = case path
      when %r{/claim\z}
        if request.fetch(:method) == :get
          @checks << request
          @read.call
        else
          { "task" => { "kind" => "tool_call", "workspace_public_id" => "ws-1", "run_public_id" => "loop-1", "conversation_public_id" => nil,
                        "parent_public_id" => nil, "task_key" => "t1",
                        "tool_name" => "work", "tool_input" => {}, "claimed" => true },
            "claim" => { "claim_token" => "claim-1", "deadline_at" => (Time.now + 8).iso8601(3) } }
        end
      when %r{/commit\z}
        @commits << request.fetch(:body)
        { "task" => { "status" => "completed" } }
      else
        raise "unexpected request: #{path}"
      end
      CybrosAgent::Response.new(status: 200, headers: {}, body: body)
    end
  end

  class Log
    attr_reader :warnings
    def initialize = @warnings = Queue.new
    def info(*, **) = nil
    def warn(event, **fields) = @warnings << [event, fields]
  end

  def setup
    @now = 0.0
    @transport = Transport.new
    @log = Log.new
    @entered = Queue.new
    @release = Queue.new
    @read_started = Queue.new
    @read_release = Queue.new
    @cancellations = Queue.new
    @pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
  end

  def teardown
    @read_release << true
    @release << true
    @caller&.join(2)
    @pool.stop
  end

  def test_a_failed_status_request_preserves_the_live_handler_and_original_deadline
    reads = 0
    provider = lambda do
      reads += 1
      raise CybrosAgent::Credentials::NotDurable, "credential write failed" if reads == 2

      "executor-token"
    end
    start_task(provider: provider)
    deadline = @context.deadline
    @now = 5.0
    assert @log.warnings.pop(timeout: 2), "the due read must reach the credential failure"
    assert_nil @caller.join(0.05)
    assert_equal 1, @pool.in_flight
    ticket = @pool.reserve
    refute_nil ticket, "the waiting handler allows other work to start"
    @pool.release(ticket)
    assert_equal deadline, @context.deadline
    refute @context.cancelled?
    assert_empty @transport.commits
    assert_empty @transport.checks, "credential failure occurs before the status request leaves"
    @release << true
    assert @caller.join(2)
    assert_equal "effect completed", @transport.commits.fetch(0).fetch("content")
    assert_equal 0, @pool.in_flight
    assert_equal 3, reads
  end

  def test_a_slow_status_http_request_may_finish_after_the_original_deadline
    @transport.read = lambda do
      @read_started << true
      @read_release.pop
      { "claim" => { "active" => true } }
    end
    start_task
    assert_deadline_after_control_return
    assert_equal 30.0, @transport.checks.fetch(0).fetch(:timeout)
  end

  def test_a_slow_credential_read_may_finish_after_the_original_deadline
    reads = 0
    provider = lambda do
      reads += 1
      if reads == 2
        @read_started << true
        @read_release.pop
      end
      "executor-token"
    end
    start_task(provider: provider)
    assert_deadline_after_control_return
    assert_equal 3, reads, "claim, status, and the final commit use the existing credential owner"
  end

  def test_a_late_inactive_read_cancels_only_its_original_context_once
    @transport.read = lambda do
      @read_started << true
      @read_release.pop
      { "claim" => { "active" => false } }
    end
    start_task
    @now = 5.0
    assert @read_started.pop(timeout: 2)
    replacement = Rho::Runner::ExecutionContext.new(
      run_public_id: "loop-1", task_key: "t1", claim_token: "claim-2")
    assert @pool.cancel(run_public_id: "loop-1", task_key: "t1")
    assert @pool.cancel(run_public_id: "loop-1", task_key: "t1")
    @read_release << true
    assert @caller.join(2)
    assert_equal :canceled, @cancellations.pop(timeout: 1)
    assert @cancellations.empty?, "Cable and the delayed read share one cancellation transition"
    refute replacement.cancelled?
    assert_equal "claim-1", @transport.checks.fetch(0).fetch(:headers).fetch("Claim-Token")
  end

  def test_a_late_accepted_extension_moves_the_deadline_unless_execution_was_already_canceled
    [false, true].each do |canceled|
      @now = 0.0
      context = nil
      extension = Rho::Runner::DeadlineExtension.new(park_seconds: 10, deadline_at: "first", clock: -> { @now }) do
        @now = 11.0
        context.cancel(:canceled) if canceled
        [20.0, "extended", 10.0]
      end
      context = Rho::Runner::ExecutionContext.new(deadline: 10.0, clock: -> { @now }, extension: extension)
      @now = 5.0
      context.renew!

      assert_equal canceled ? 10.0 : 20.0, context.deadline,
        "a real server extension can move the clock; elapsed HTTP alone cannot"
      assert_equal canceled, context.cancelled?
      assert_equal "extended", extension.deadline_at
    end
  end

  private

    def start_task(provider: -> { "executor-token" })
      executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: @transport,
        credential_provider: provider)
      tool = Rho::Runner::Toolset::Tool.new(name: "work", description: "work", internal_clamp: true,
        parameters: { "type" => "object" }, handler: lambda { |_input, context|
          Rho::Runner::ExecutionContext.with_cancel_signal(-> { @release << true }) do
            @entered << context
            @release.pop
            context.raise_if_cancelled!
            Rho::Runner::Result.ok("effect completed")
          end
        })
      tools = Rho::Runner::Toolsets.fixed(toolset: Rho::Runner::Toolset.new("work" => tool))
      run = Rho::Runner::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: @log,
        clock: -> { @now }, on_cancel: ->(reason) { @cancellations << reason })
      @caller = Thread.new { run.call(run_public_id: "loop-1", task_key: "t1") }
      @context = @entered.pop(timeout: 2)
      refute_nil @context
    end

    def assert_deadline_after_control_return
      deadline = @context.deadline
      @now = 5.0
      assert @read_started.pop(timeout: 2)
      @now = deadline + 1
      assert_nil @caller.join(0.05), "an in-flight control request is allowed to finish"
      assert_equal 1, @pool.in_flight
      ticket = @pool.reserve
      refute_nil ticket, "a control request does not occupy handler startup capacity"
      @pool.release(ticket)
      assert_equal deadline, @context.deadline
      assert_empty @transport.commits
      @read_release << true
      assert @caller.join(2)
      assert_equal :deadline, @context.reason
      assert_equal deadline, @context.deadline
      @context.renew!
      assert_equal 1, @transport.checks.length, "no probe starts after expiry"
      assert_equal 0, @pool.in_flight
    end
end
