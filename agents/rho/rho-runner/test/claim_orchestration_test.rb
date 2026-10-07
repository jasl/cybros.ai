require "test_helper"

class ClaimOrchestrationTest < Minitest::Test
  State = Data.define(:status, :requests, :result, :error)

  class Runtime
    attr_reader :threads, :programs, :events
    attr_accessor :result

    def initialize
      @threads = []
      @programs = []
      @events = []
      @result = { "content" => [{ "type" => "text", "text" => "done" }], "structured_content" => nil }
    end

    def call(program:, cancelled:)
      @threads << Thread.current
      @programs << program
      raise "cancellation reached VM" if cancelled.call

      @events.concat(yield(State.new(status: "request", requests: [{ "key" => "op_0",
        "request" => { "kind" => "tool", "name" => "child", "input" => {} } }], result: nil, error: nil)))
      @events.concat(yield(State.new(status: "observe", requests: [], result: nil, error: nil)))
      State.new(status: "finished", requests: [], result: @result, error: nil)
    end
  end

  class Transport
    ENVIRONMENT = { "default_runner_executor_public_id" => "runner-a",
      "executors" => [{ "runner_executor_public_id" => "runner-a", "environment" => { "root" => "/captured/project" } }],
      "skills" => [{ "callable" => "read_skill", "name" => "review", "source" => "runner", "executor_public_id" => "runner-a" }] }.freeze

    attr_accessor :child_done, :unknown_submit, :cancel_on_submit, :expire_on_submit, :context, :paginate, :submit_refusal, :submit_status, :observe_changed
    attr_reader :calls, :commits, :trace, :submits

    def initialize
      @calls = []
      @commits = []
      @trace = []
      @submits = 0
      @claims = 0
      @child_done = true
    end

    def call(path, **request)
      @calls << [path, request, Thread.current]
      body = case path
      when %r{/claim\z}
        if request[:method] == :get
          { "claim" => { "active" => true } }
        else
          @claims += 1
          parent = path.include?("/parent/")
          { "task" => { "kind" => "tool_call", "workspace_public_id" => "workspace", "run_public_id" => "run_public_id",
            "conversation_public_id" => nil, "parent_public_id" => nil, "task_key" => parent ? "parent" : "child",
            "tool_name" => parent ? "orchestrator" : "child", "tool_input" => {}, "claimed" => true },
            "claim" => { "claim_token" => "proof-#{@claims}", "deadline_at" => (Time.now + 60).iso8601(3) } }
        end
      when %r{/operations\z}
        if request.fetch(:method, :get) == :get
          after = (request[:params] || {}).fetch("after", 0)
          events = @trace.select { |event| event.fetch("position") > after }
          page = @paginate ? events.first(1) : events
          return CybrosAgent::Response.new(status: 200, headers: {}, body: {
            "operations" => { "context" => { "tools" => [{ "name" => "child" }], "model_defaults" => { "model" => "test" },
              "environment" => ENVIRONMENT },
              "trace" => page, "position" => @trace.length,
              "next_after" => page.length < events.length ? page.last.fetch("position") : nil } })
        end
        @submits += 1
        if @submit_refusal
          return CybrosAgent::Response.new(status: @submit_status || 409, headers: {}, body: {
            "error" => { "code" => @submit_refusal, "message" => "Refused" } })
        end
        operation = request.fetch(:body).fetch("operation")
        event = operation.merge("type" => "operation", "position" => @trace.length + 1, "receipt" => { "tasks" => ["child"] })
        @trace << event
        @context.cancel(:canceled) if @cancel_on_submit
        @context.cancel(:deadline) if @expire_on_submit
        if @unknown_submit
          @unknown_submit = false
          raise CybrosAgent::TransportError, "response lost after acceptance"
        end
        { "operation" => event }
      when %r{/observation\z}
        if @child_done && @trace.none? { |event| event["type"] == "observation" }
          @trace << { "type" => "observation", "position" => @trace.length + 1, "key" => "op_0", "outcome" => { "content" => "child done" } }
          if @observe_changed
            @observe_changed = false
            return CybrosAgent::Response.new(status: 409, headers: {}, body: {
              "error" => { "code" => "operation_position_changed", "message" => "Refetch observations" } })
          end
          { "observation" => @trace.last, "position" => @trace.length }
        else
          { "observation" => nil, "position" => @trace.length }
        end
      when %r{/commit\z}
        @commits << [path, request.fetch(:body)]
        @child_done = true if path.include?("/child/")
        { "task" => { "status" => "completed" } }
      else
        raise "unexpected request #{path}"
      end
      CybrosAgent::Response.new(status: 200, headers: {}, body: body)
    end
  end

  class Log
    attr_reader :warnings
    def initialize = @warnings = []
    def info(*, **) = nil
    def warn(*args, **fields) = @warnings << [args, fields]
  end

  def setup
    @transport = Transport.new
    @runtime = Runtime.new
    @pool = Rho::Runner::Pool.new(worker_threads: 1)
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", transport: @transport,
      credential_provider: -> { "executor-token" })
    parent = Rho::Runner::Toolset::Tool.new(name: "orchestrator", description: "orchestrator",
      parameters: { "type" => "object" }, handler: lambda { |_input, context|
        @transport.context = context
        context.orchestration.run(program: { "source" => "test" }, runtime: @runtime)
      })
    child = Rho::Runner::Toolset::Tool.new(name: "child", description: "child", parameters: { "type" => "object" },
      handler: ->(_input, _context) { Rho::Runner::Result.ok("child done") })
    tools = Rho::Runner::Toolsets.fixed(toolset: Rho::Runner::Toolset.new("orchestrator" => parent, "child" => child))
    @log = Log.new
    @run = Rho::Runner::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: @log)
  end

  def teardown = @pool.stop

  def test_one_worker_keeps_the_live_parent_and_executes_its_child_before_one_final_commit
    @transport.child_done = false
    Async do |reactor|
      reactor.with_timeout(3) do
        parent = reactor.async { run_task("parent") }
        sleep(0.01) until @transport.submits.positive?
        assert_equal 1, @pool.in_flight
        assert_equal :done, run_task("child")
        assert_equal :done, parent.wait
      end
    end
    assert_equal 1, @transport.submits
    assert_equal 1, @runtime.programs.length, "source is invoked once under one claim"
    assert_equal %w[child parent], @transport.commits.map { |path, _| path.split("/")[-2] }
    final = @transport.commits.last.last
    assert_equal [{ "type" => "text", "text" => "done" }], final.fetch("content")
    assert final.key?("structured_content")
    assert_nil final.fetch("structured_content")
    assert @runtime.threads.none? { |thread| thread == Thread.current }
    assert @transport.calls.all? { |_, _, thread| thread == Thread.current }
    assert_equal [{ "name" => "child" }], @runtime.programs.first.fetch("tools")
    assert_equal({ "model" => "test" }, @runtime.programs.first.fetch("model_defaults"))
    assert_equal Transport::ENVIRONMENT, @runtime.programs.first.fetch("environment")
  end

  def test_a_ready_outcome_preserves_resource_links_and_false_in_the_same_claim
    @runtime.result = { "content" => [{ "type" => "resource_link", "uri" => "nexus://uploads/artifact", "name" => "report" }],
      "structured_content" => false }
    assert_equal :done, run_task("parent")
    assert_equal 1, @transport.commits.length
    assert_equal @runtime.result, @transport.commits.last.last.slice("content", "structured_content")
  end

  def test_an_unknown_submit_response_reads_its_receipt_without_restarting_or_resubmitting
    @transport.unknown_submit = true
    run_task("parent")
    assert_equal 1, @runtime.programs.length
    assert_equal 1, @transport.submits
    assert_equal "completed", @transport.commits.last.last.fetch("outcome")
    assert_empty @log.warnings
  end

  def test_cancellation_during_a_control_request_stops_before_observation_or_a_second_operation
    @transport.cancel_on_submit = true
    run_task("parent")
    assert_equal 1, @transport.submits
    assert_equal "failed", @transport.commits.last.last.fetch("outcome")
    assert_match(/interrupted/, @transport.commits.last.last.fetch("content"))
    refute @transport.calls.any? { |path, _, _| path.end_with?("/observation") }
  end

  def test_a_deadline_returns_an_ordinary_timeout_and_never_restarts_the_handler
    @transport.expire_on_submit = true
    assert_equal :done, run_task("parent")
    final = @transport.commits.last.last
    assert_equal "completed", final.fetch("outcome")
    assert final.fetch("is_error")
    assert_match(/timed out/, final.fetch("content"))
    assert_equal ["operation"], @transport.trace.map { |event| event.fetch("type") }
    assert_equal 1, @runtime.programs.length
    assert_equal 0, @pool.in_flight
  end

  def test_existing_operation_history_cannot_reconstruct_a_lost_execution
    run_task("parent")
    @transport.paginate = true
    run_task("parent")
    assert_equal 1, @runtime.programs.length
    assert_equal 1, @transport.submits
    assert_equal "failed", @transport.commits.last.last.fetch("outcome")
    assert_match(/previous execution state is unavailable/, @transport.commits.last.last.fetch("content"))
  end

  def test_a_stale_claim_does_not_run_or_observe_more_work
    @transport.submit_refusal = "not_claimant"
    run_task("parent")
    assert_equal 1, @transport.submits
    assert_equal 1, @runtime.programs.length
    refute @transport.calls.any? { |path, _, _| path.end_with?("/observation") }
    assert_equal "failed", @transport.commits.last.last.fetch("outcome")
    assert_equal 0, @pool.in_flight
  end

  def test_an_operation_mismatch_fails_the_parent_without_executing_or_observing_more_work
    @transport.submit_refusal = "operation_mismatch"
    run_task("parent")
    assert_equal 1, @transport.submits
    assert_equal "failed", @transport.commits.last.last.fetch("outcome")
  end

  def test_a_definite_invalid_or_oversized_request_fails_without_resubmitting
    @transport.submit_refusal = "invalid_operation"
    [400, 422, 413].each do |status|
      @transport.submit_status = status
      run_task("parent")
      assert_equal "failed", @transport.commits.last.last.fetch("outcome"), "HTTP #{status} refused acceptance"
    end
    assert_equal 3, @transport.submits
    assert_equal 3, @transport.commits.length
    assert_empty @transport.trace
  end

  def test_authority_and_server_failures_end_this_invocation_without_source_replay
    @transport.submit_refusal = "invalid_operation"
    [401, 403, 404, 409, 503].each do |status|
      @transport.submit_status = status
      run_task("parent")
    end
    assert_equal 5, @transport.submits
    assert_equal 5, @runtime.programs.length
    assert @transport.commits.all? { |_, body| body.fetch("outcome") == "failed" }
    assert_equal 0, @pool.in_flight
  end

  def test_a_changed_position_reads_the_saved_observation_into_the_same_invocation
    @transport.observe_changed = true
    run_task("parent")
    assert_equal 2, @transport.calls.count { |path, request, _| path.end_with?("/operations") && request.fetch(:method, :get) == :get }
    assert_equal 1, @runtime.programs.length
    assert_equal %w[operation observation], @runtime.events.map { |event| event.fetch(:type) }
    assert_equal 1, @transport.submits
    assert_equal "completed", @transport.commits.last.last.fetch("outcome")
  end

  def test_dropping_oversized_structure_keeps_the_result_resource_links
    link = { "type" => "resource_link", "uri" => "nexus://uploads/artifact", "name" => "report" }
    @runtime.result = { "content" => [link], "structured_content" => "x" * 1_048_576 }
    run_task("parent")
    result = @transport.commits.last.last
    assert_equal link, result.fetch("content").first
    assert_match(/structured content omitted/, result.fetch("content").last.fetch("text"))
    refute result.key?("structured_content")
  end

  private

    def run_task(key)
      @run.call(run_public_id: "run_public_id", task_key: key)
    end
end
