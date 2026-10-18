require_relative "test_helper"

class ClaimBridgeTest < Minitest::Test
  # This fixture is the SDK task boundary. The real runner mailbox, worker pool,
  # Code adapter and V8 runtime stay active under the original claim. This pins host behavior;
  # kernel acceptance is exercised separately through its public boundary.
  class TaskFixture
    attr_reader :calls, :trace, :submissions, :requests
    attr_accessor :paused_submissions, :on_submit

    def initialize
      @calls = []
      @trace = []
      @submissions = 0
      @requests = []
      @paused_submissions = 0
      @outcome = nil
      @tools = [
        { "type" => "function", "function" => { "name" => "read", "parameters" => { "type" => "object" } } },
        { "type" => "function", "function" => { "name" => "code", "parameters" => Rho::Codemode::Code::SCHEMA } },
      ]
    end

    def operations(claim_token:)
      record(:operations, claim_token)
      CybrosAgent::Api::TaskOperations.new(
        context: CybrosAgent::Api::OperationContext.new(tools: @tools, model_defaults: {}),
        trace: @trace.dup, position: @trace.length
      )
    end

    def submit(key:, request:, claim_token:)
      record(:submit, claim_token)
      @requests << { key: key, request: request, claim_token: claim_token }
      @on_submit&.call
      if @paused_submissions.positive?
        @paused_submissions -= 1
        raise CybrosAgent::Api::Conflict.new("Execution is paused", code: "execution_paused")
      end
      @submissions += 1
      event = CybrosAgent::Api::OperationEvent.new(type: "operation", position: @trace.length + 1,
        key: key, request: request, receipt: { "task_keys" => ["child"], "result_task_keys" => ["child"], "steps" => [] })
      @trace << event
      event
    end

    def observe(after:, claim_token:)
      record(:observe, claim_token)
      if @outcome
        event = CybrosAgent::Api::OperationEvent.new(type: "observation", position: @trace.length + 1,
          key: "op_0", outcome: @outcome)
        @trace << event
        CybrosAgent::Api::OperationRead.new(observation: event, position: @trace.length)
      else
        CybrosAgent::Api::OperationRead.new(observation: nil, position: @trace.length)
      end
    end

    def complete_child
      @outcome = { "status" => "completed", "is_error" => false,
        "content" => [{ "type" => "text", "text" => "child complete" }], "structured_content" => false }
      Thread.current
    end

    private

      def record(method, token)
        @calls << { method: method, token: token, thread: Thread.current }
      end
  end

  class CountingRuntime < Rho::Codemode::Runtime
    attr_reader :starts

    def initialize
      super
      @starts = 0
    end

    def call(...)
      @starts += 1
      super
    end
  end

  def test_a_paused_submission_keeps_one_live_vm_until_the_same_request_is_accepted
    task = TaskFixture.new
    task.paused_submissions = 2
    task.complete_child
    runtime = CountingRuntime.new
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    context = context(task, "original-claim")
    program = { "source" => "let kept = 40; const child = await tools.read(params); kept += 2; text(child.content[0].text); return kept;",
      "params" => { "path" => "README.md" } }
    result = pool.run(pool.reserve, context) { context.orchestration.run(program: program, runtime: runtime) }
    assert_equal 1, runtime.starts
    assert_equal 42, result.structured_content
    assert_equal [{ "type" => "text", "text" => "child complete" }], result.content
    assert_equal 3, task.requests.length
    assert_equal 1, task.requests.uniq.length
    assert_equal 1, task.submissions
    assert_equal %w[operation observation], task.trace.map(&:type)
    assert task.calls.all? { |call| call.fetch(:thread) == Thread.current }
  ensure
    pool&.stop
  end

  def test_canceling_a_vm_after_a_paused_refusal_does_not_submit_again
    task = TaskFixture.new
    task.paused_submissions = 1
    runtime = CountingRuntime.new
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    context = context(task, "original-claim")
    task.on_submit = -> { context.cancel(:canceled) }
    error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
      pool.run(pool.reserve, context) do
        context.orchestration.run(program: { "source" => "return await tools.read({path:'README.md'});" }, runtime: runtime)
      end
    end
    assert_equal :canceled, error.reason
    assert_equal 1, runtime.starts
    assert_equal 1, task.requests.length
    assert_equal 0, task.submissions
    assert_empty task.trace
  ensure
    pool&.stop
  end

  def test_live_vms_release_startup_capacity_while_waiting_for_children_on_the_same_executor
    pool = nil
    [[1, 1], [3, 9]].each do |workers, parents|
      tasks = Array.new(parents) { TaskFixture.new }
      pool = Rho::Runner::Pool.new(worker_threads: workers)
      tool = Rho::Codemode::Code.new(env: nil)
      args = { "code" => "const result = await tools.read(params); text(result.content[0].text); return result.structured_content;", "params" => { "path" => "README.md" } }
      results = Async do |reactor|
        reactor.with_timeout(5) do
          waiting = tasks.map.with_index do |task, index|
            reactor.async do
              ticket = nil
              sleep(0.001) until (ticket = pool.reserve)
              pool.run(ticket, context(task, "claim-#{index}")) { tool.call(args) }
            end
          end
          sleep(0.01) until tasks.all? { |task| task.submissions == 1 }
          assert_equal parents, pool.in_flight
          tasks.each do |task|
            child_thread = pool.run(pool.reserve, Rho::Runner::ExecutionContext.new) { task.complete_child }
            refute_equal Thread.current, child_thread
          end
          waiting.map(&:wait)
        end
      end.wait
      results.each do |result|
        assert_equal [{ "type" => "text", "text" => "child complete" }], result.content
        assert_equal false, result.structured_content
        assert result.structured_content_present
      end
      tasks.each_with_index do |task, index|
        assert_equal 1, task.submissions
        assert_equal %w[operation observation], task.trace.map(&:type)
        assert task.calls.all? { |call| call.fetch(:thread) == Thread.current }, "SDK calls stay on the control reactor"
        assert_equal ["claim-#{index}"], task.calls.map { |call| call.fetch(:token) }.uniq
      end
      assert_equal 0, pool.in_flight
      pool.stop
    end
  ensure
    pool&.stop
  end

  def test_accepted_work_refuses_an_unsupported_binding_before_observing_or_submitting
    task = TaskFixture.new
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    args = { "code" => "return await tools.read({path:'one'});" }
    binding = Rho::Codemode::Code::BINDING_ID
    Rho::Codemode::Code.send(:remove_const, :BINDING_ID)
    Rho::Codemode::Code.const_set(:BINDING_ID, "urn:cybros:rho:codemode:javascript:2")
    error = assert_raises(Rho::Runner::ClaimOrchestration::Failure) do
      pool.run(pool.reserve, context(task, "claim")) { Rho::Codemode::Code.new(env: nil).call(args) }
    end
    assert_match(/unsupported_binding/, error.message)
    assert_equal 0, task.submissions
    assert_equal [:operations], task.calls.map { |call| call.fetch(:method) }
  ensure
    if binding
      Rho::Codemode::Code.send(:remove_const, :BINDING_ID)
      Rho::Codemode::Code.const_set(:BINDING_ID, binding)
    end
    pool&.stop
  end

  private

    def context(task, token)
      bridge = Rho::Runner::ClaimOrchestration.new(task:, claim_token: token, log: nil)
      Rho::Runner::ExecutionContext.new(orchestration: bridge,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2)
    end
end
