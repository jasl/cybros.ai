require "test_helper"
require_relative "task_operation_growth_metrics"

# Explicit only: OPERATION_WIDTHS=10,100,1000 PARALLEL_WORKERS=1 \
#   bin/rails test test/benchmarks/task_operation_growth.rb
# Authenticated Rack requests exercise the ordinary task-operation lifecycle.
# Child IO is deterministic; no JavaScript runtime, TCP, Puma or provider IO.
class TaskOperationGrowthBenchmark < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RunLaneTestHelper

  WIDTHS = ENV.fetch("OPERATION_WIDTHS", "10,100,1000").split(",").map { |value| Integer(value) }.freeze
  SCENARIOS = ENV.fetch("OPERATION_SCENARIOS", "sequential,parallel").split(",").freeze
  SAMPLES = Integer(ENV.fetch("OPERATION_SAMPLES", "1"))
  RESULT_BYTES = 128

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @runner = suite_runner
    assert_predicate @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }]), :accepted?
    @metrics = TaskOperationGrowthMetrics.new
    Thread.current[:task_operation_growth_metrics] = @metrics
  end

  teardown do
    Thread.current[:task_operation_growth_metrics] = nil
    @metrics.close
  end

  WIDTHS.each do |width|
    SCENARIOS.each do |scenario|
      SAMPLES.times do |sample|
        test("#{scenario} #{width} operations sample #{sample + 1}") { measure_program(width, scenario, sample + 1) }
      end
    end

    if ENV["OPERATION_CONTENTION"] == "1"
      name = "concurrent submits #{width} operations"
      uses_transaction "test_#{name.tr(" ", "_")}"
      test(name) { measure_contention(width) }
    end
  end

  private

    def measure_program(width, scenario, sample)
      @loop = seed(program_step("program"))
      @trace = []
      @completed = []
      @position = 0
      @trace_page_bytes = 0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      start_loop
      @parent_key = @loop.agent_run_tasks.sole.node_key
      claim = request_json(:post, "claim", phase: :http_parent_claim)
      @token = claim.dig("claim", "claim_token")
      initial = trace_pages
      assert_empty initial

      case scenario
      when "sequential"
        width.times do |index|
          event = submit(index)
          assert_nil observe
          finish_child(event)
          assert_equal event.fetch("key"), observe.fetch("key")
        end
      when "parallel"
        events = width.times.map { |index| submit(index) }
        assert_nil observe
        events.reverse_each do |event|
          finish_child(event)
          assert_equal event.fetch("key"), observe.fetch("key")
        end
      else
        raise ArgumentError, "unknown scenario #{scenario}"
      end

      request_json(:post, "commit", phase: :http_final,
        params: { claim_token: @token, content: "done", structured_content: width })
      parent = @loop.agent_run_tasks.find_by!(node_key: @parent_key)
      assert_equal "completed", parent.status
      assert_equal @token, parent.claim_token
      assert_equal 0, parent.execution_generation
      assert_equal width, @completed.uniq.length
      assert_equal width + 1, @loop.agent_run_tasks.count
      assert_equal width, parent.task_operations.where.not(observed_position: nil).count
      assert_equal @trace, trace_pages
      @outcome = "completed"
    ensure
      if @trace
        puts JSON.generate(benchmark: "task_operation_growth", scenario: scenario, width: width,
          sample: sample, outcome: @outcome || "failed", completed_children: @completed.length,
          trace_events: @trace.length, trace_bytes: JSON.generate(@trace).bytesize,
          trace_page_response_bytes: @trace_page_bytes,
          wall_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3),
          nexus_rss_kib: IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).to_i,
          result_bytes: RESULT_BYTES, phases: @metrics.summary)
      end
    end

    def submit(index)
      body = request_json(:post, "operations", phase: :http_submit,
        params: { claim_token: @token, operation: { key: "op_#{index}", request: { kind: "tool",
          name: "read_file", input: { index: index } } } })
      event = body.fetch("operation")
      assert_nil event["refusal"], event.inspect
      @position = event.fetch("position")
      @trace << event
      event
    end

    def observe
      body = request_json(:post, "observation", phase: :http_observe,
        params: { claim_token: @token, after: @position })
      @position = body.fetch("position")
      event = body["observation"]
      @trace << event if event
      event
    end

    def finish_child(event)
      schedule
      child = event.dig("receipt", "task_keys").sole
      index = event.dig("request", "input", "index")
      claim = request_json(:post, "claim", phase: :http_child_claim, task_key: child)
      request_json(:post, "commit", phase: :http_child_commit, task_key: child,
        params: { claim_token: claim.dig("claim", "claim_token"),
          content: "result #{index}".ljust(RESULT_BYTES, "x"), structured_content: { value: index + 1 } })
      @completed << child
    end

    def trace_pages
      events = []
      after = 0
      loop do
        body = request_json(:get, "operations", phase: :http_trace, params: { after: after, limit: 100 },
          headers: { "Claim-Token" => @token })
        @trace_page_bytes += response.body.bytesize
        page = body.fetch("operations")
        events.concat(page.fetch("trace"))
        after = page["next_after"]
        break unless after
      end
      events
    end

    # Two valid parents serialize ordinary Submit calls on one loop. SQL
    # duration includes execution and lock waiting, not just lock waiting.
    def measure_contention(width)
      @loop = seed(parallel(program_step("left"), program_step("right")), tool("joined", "read_file"))
      start_loop
      parents = @loop.agent_run_tasks.where(tool_name: "program").order(:id).map do |node|
        body = request_json(:post, "claim", phase: :http_parent_claim, task_key: node.node_key)
        { key: node.node_key, token: body.dig("claim", "claim_token") }
      end
      ready = Thread::Queue.new
      go = Thread::Queue.new
      threads = parents.map do |parent|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            agent_run = AgentRun.find(@loop.id)
            access = Executors::TaskOperations::Access.new(agent_run: agent_run,
              task_key: parent.fetch(:key), executor: TaskExecutor.find(@runner.id), claim_token: parent.fetch(:token))
            metrics = TaskOperationGrowthMetrics.new
            Thread.current[:task_operation_growth_metrics] = metrics
            ready << true
            go.pop
            width.times do |index|
              result = Executors::TaskOperations::Submit.new(access: access, key: "op_#{index}",
                request: { "kind" => "tool", "name" => "read_file", "input" => { "index" => index } }).call
              raise "submit failed: #{result.outcome}" unless result.accepted?
              raise "child refused: #{result.value}" if result.value.dig("operation", "refusal")
            end
            { accepted: width, phases: metrics.summary.transform_values { |phase| phase.except(:allocations) } }
          ensure
            metrics&.close
            Thread.current[:task_operation_growth_metrics] = nil
          end
        end
      end
      parents.length.times { ready.pop }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      parents.length.times { go << true }
      readings = threads.map(&:value)
      puts JSON.generate(benchmark: "task_operation_contention", width: width, parents: parents.length,
        wall_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3), readings: readings)
      assert_equal width * parents.length, AgentRunTaskOperation.where(agent_run_task_id: @loop.agent_run_tasks.select(:id)).count
    ensure
      threads&.each(&:join)
      clear_enqueued_jobs
      AgentRuns::Reap.destroy_aggregate(@loop) if @loop
    end

    def program_step(key)
      tool(key, "program", "route" => { "kind" => "runner" }, "timeout_ms" => 3_600_000,
        "model_defaults" => { "tools" => fixture_runner_declarations([READ_TOOL]),
          "model" => { "model" => "dev/mock-text" } })
    end

    def start_loop
      result = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @loop, acting_user: @human))
      assert_predicate result, :accepted?
      schedule
    end

    def schedule
      @metrics.capture(:schedule) { AgentRuns::ScheduleReady.call(agent_run_id: @loop.id) }
      clear_enqueued_jobs
    end

    def request_json(verb, action, phase:, params: {}, headers: {}, task_key: @parent_key)
      @metrics.capture(phase) do
        public_send(verb, "/agent_api/v1/executor/inbox/#{@loop.public_id}/#{task_key}/#{action}",
          params: params, headers: { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
            .merge(headers), as: :json)
      end
      assert response.successful?, "#{action} #{response.status}: #{response.body}"
      response.parsed_body
    end
end
