require "test_helper"

# Run explicitly: PARALLEL_WORKERS=1 bin/rails test test/benchmarks/fan_completion_growth.rb
# A real model result authors the fan; executor claims prepare the starting state.
# Only provider IO is faked. Every measured commit gets its own schedule wake,
# matching a worker that runs each queued wake before the next result arrives.
# Each savepoint restores the same claimed fan for both cache modes and all samples.
class FanCompletionGrowthBenchmark < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  RESULT_BYTES = 128
  SAMPLE_COUNT = 3
  COUNTERS = %i[queries cache_hits rows cached_rows records elapsed_ms allocations].freeze
  Claim = Data.define(:task_key, :claim_token, :call_id, :content)

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @executor = TaskExecutor.address_for(@agent)
  end

  # A kernel fan's current authoring limit is 256 members, plus its one
  # continuation. Stay within that public behavior instead of inserting a
  # graph the current round driver cannot author.
  [10, 100, 256].each do |width|
    test "measure completion and wakes for #{width} tool calls" do
      agent_run, continuation, claims = prepare_fan(width)
      node_count = agent_run.agent_run_tasks.count

      sample(agent_run, continuation, claims, cached: true)
      [true, false].each do |cached|
        samples = Array.new(SAMPLE_COUNT) do
          sample(agent_run, continuation, claims, cached: cached)
        end
        puts JSON.generate(operation: "fan_completion_and_wakes", tools: width,
          nodes: node_count, result_bytes: RESULT_BYTES, completion_order: "reverse",
          query_cache: cached, samples: samples)
      end
    end
  end

  private

    def prepare_fan(width)
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
        answering_user: @agent)
      post_input!(conversation, acting_user: @human, text: "read the files")
      _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent, text: nil,
        model_ref: "mock-windowless")
      schedule_loop!(agent_run)
      calls = Array.new(width) do |index|
        { id: "call_#{index}", name: "read_file", arguments: { path: "docs/#{index}.txt" }.to_json }
      end
      run_loop_round!(agent_run, sse_success("reading the files", tool_calls: calls))

      continuation = agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name,
        status: "queued").sole
      assert_equal width, continuation.remaining_dependencies
      assert_nil continuation.selected_model_invocation_id
      assert_equal 1, agent_run.model_invocations.count

      claims = calls.each_with_index.map do |call, index|
        node = agent_run.agent_run_tasks.find_by!(tool_call_id: call.fetch(:id))
        assert_equal "dispatched", node.status
        claimed = Executors::Claim.call(Executors::Claim::Command.new(
          agent_run: agent_run, task_key: node.node_key, executor: @executor
        ))
        assert_predicate claimed, :accepted?, claimed.outcome.inspect
        Claim.new(task_key: node.node_key, claim_token: claimed.value.claim_token,
          call_id: call.fetch(:id), content: "result #{index}\n".ljust(RESULT_BYTES, "x"))
      end
      clear_enqueued_jobs
      [agent_run, continuation, claims]
    end

    def sample(agent_run, continuation, claims, cached:)
      counts = nil
      ApplicationRecord.transaction(requires_new: true) do
        counts = measure do |capture|
          claims.reverse_each.with_index do |claim, index|
            result = nil
            with_query_cache(cached) do
              capture.call(:commit) do
                result = commit(AgentRun.find(agent_run.id), claim)
              end
            end
            assert_predicate result, :applied?, result.outcome.inspect

            with_query_cache(cached) do
              capture.call(:wake) { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
            end
            # These reads and assertions are outside the timed/counted phases.
            # A warm SQL cache never carries between these separate requests.
            current = AgentRunTask.find(continuation.id)
            if index < claims.length - 1
              assert_equal "queued", current.status, "a partial fan must keep waiting"
              assert_nil current.selected_model_invocation_id, "no early continuation invocation"
            else
              assert_equal "running", current.status
              assert_not_nil current.selected_model_invocation_id
            end
            clear_enqueued_jobs
          end
        end

        current = AgentRunTask.find(continuation.id)
        assert_equal 2, agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name).count
        assert_equal 2, agent_run.model_invocations.count, "exactly one continuation was started"
        assert_equal claims.length, agent_run.agent_run_tasks.where(
          type: AgentRunTasks::ToolTask.sti_name, status: "completed"
        ).count
        entries = round_request_entries(current)
        calls = entries.select { |entry| entry["type"] == "tool_call_item" }
        results = entries.select { |entry| entry["type"] == "tool_result_item" }
        assert_equal claims.map(&:call_id), calls.map { |entry| entry.dig("payload", "call_id") }
        assert_equal claims.map(&:call_id), results.map { |entry| entry.dig("payload", "call_id") }
        assert_equal claims.map(&:content), results.map { |entry| entry.dig("payload", "output") },
          "out-of-order completions still replay every result in call order"

        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
        assert_equal 2, agent_run.model_invocations.count, "a duplicate wake starts nothing twice"
        raise ActiveRecord::Rollback
      end
      clear_enqueued_jobs
      counts
    end

    def commit(agent_run, claim)
      Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: agent_run, task_key: claim.task_key, executor: @executor,
        claim_token: claim.claim_token, content: claim.content, structured_content: nil,
        result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
    end

    # Each commit and wake is a separate request/job. Cached mode permits
    # reuse within that operation only; neither setup nor an earlier sample
    # supplies cached rows to it.
    def with_query_cache(cached, &block)
      ApplicationRecord.connection.clear_query_cache
      cached ? ApplicationRecord.cache(&block) : ApplicationRecord.uncached(&block)
    end

    def measure
      counts = %i[commit wake].index_with do
        COUNTERS.index_with { 0 }.merge(record_classes: Hash.new(0))
      end
      phase = nil
      sql_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if phase.nil? || payload[:name].in?(%w[SCHEMA TRANSACTION])

        current = counts.fetch(phase)
        current[payload[:cached] ? :cache_hits : :queries] += 1
        current[payload[:cached] ? :cached_rows : :rows] += payload[:row_count].to_i
      end
      record_subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        next if phase.nil?

        current = counts.fetch(phase)
        count = payload.fetch(:record_count)
        current[:records] += count
        current[:record_classes][payload.fetch(:class_name)] += count
      end

      capture = lambda do |name, &operation|
        phase = name
        allocated = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        operation.call
      ensure
        current = counts.fetch(name)
        current[:elapsed_ms] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
        current[:allocations] += GC.stat(:total_allocated_objects) - allocated
        phase = nil
      end
      GC.start
      yield capture

      total = COUNTERS.index_with { |key| counts.values.sum { |part| part.fetch(key) } }
      total[:record_classes] = Hash.new(0)
      counts.each_value do |part|
        part.fetch(:record_classes).each { |name, count| total[:record_classes][name] += count }
      end
      counts[:total] = total
      counts.each_value { |part| part[:elapsed_ms] = part.fetch(:elapsed_ms).round(3) }
      counts
    ensure
      ActiveSupport::Notifications.unsubscribe(sql_subscriber)
      ActiveSupport::Notifications.unsubscribe(record_subscriber)
    end
end
