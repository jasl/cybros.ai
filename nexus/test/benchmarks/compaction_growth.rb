require "test_helper"

# Run explicitly: PARALLEL_WORKERS=1 bin/rails test test/benchmarks/compaction_growth.rb
# Real invocation/round/tool writers prepare the graph; only provider IO is faked.
# Setup is outside the samples. Each savepoint rolls the measured repair back so
# cache modes and repetitions start from the same queued round and stored history.
class CompactionGrowthBenchmark < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  FINAL_FAN_SIZE = 20
  RESULT_BYTES = 60.kilobytes
  SAMPLE_COUNT = 3

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
  end

  [10, 100, 500].each do |round_count|
    test "measure wall to prune after #{round_count} rounds" do
      agent_run, next_round = prepare_wall(round_count)
      expected_calls = round_count - 1 + FINAL_FAN_SIZE
      node_count = agent_run.agent_run_tasks.count

      sample(agent_run, next_round, expected_calls, cached: true)
      [true, false].each do |cached|
        samples = Array.new(SAMPLE_COUNT) do
          sample(agent_run, next_round, expected_calls, cached: cached)
        end
        puts JSON.generate(operation: "schedule_wall_to_prune", rounds: round_count,
          nodes: node_count, final_fan: FINAL_FAN_SIZE, result_bytes: RESULT_BYTES,
          query_cache: cached, samples: samples)
      end
    end
  end

  private

    def prepare_wall(round_count)
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
        answering_user: @agent)
      post_input!(conversation, acting_user: @human, text: "read the files")
      _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent, text: nil,
        model_ref: "mock-windowless")
      schedule_loop!(agent_run)

      round_count.times do |index|
        final = index == round_count - 1
        calls = Array.new(final ? FINAL_FAN_SIZE : 1) do |fan|
          { id: "call_#{index}_#{fan}", name: "read_file",
            arguments: { path: "docs/#{index}/#{fan}.txt" }.to_json }
        end
        run_loop_round!(agent_run, sse_success("reading #{index}", tool_calls: calls))
        calls.each do |call|
          content = "file #{call.fetch(:id)}\n"
          content = content.ljust(RESULT_BYTES, "x") if final
          settled = AgentRuns::Parks::Settle.call(
            node: agent_run.agent_run_tasks.find_by!(tool_call_id: call.fetch(:id)),
            trusted: true, content: content, outcome: "completed"
          )
          assert_predicate settled, :applied?
        end
        clear_enqueued_jobs
        schedule_loop!(agent_run) unless final
      end

      next_round = agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name,
        status: "queued").sole
      assert_nil next_round.pruned_before
      assert_equal round_count, agent_run.agent_run_tasks.where(
        type: AgentRunTasks::ModelTask.sti_name, status: "completed"
      ).count
      assert_not agent_run.agent_run_tasks.where("compaction ? :pruned OR compaction ? :summary",
        pruned: AgentRunTasks::ModelTask::PRUNED_BEFORE,
        summary: AgentRunTasks::ModelTask::SUMMARY_SOURCE).exists?,
        "preparation must reach its first wall only at the measured round"
      [agent_run, next_round]
    end

    def sample(agent_run, next_round, expected_calls, cached:)
      counts = nil
      ApplicationRecord.transaction(requires_new: true) do
        ApplicationRecord.connection.clear_query_cache
        operation = lambda do
          counts = measure { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
        end
        cached ? ApplicationRecord.cache(&operation) : ApplicationRecord.uncached(&operation)

        next_round.reload
        assert_equal "running", next_round.status, "the same schedule pass must restart after pruning"
        assert_equal next_round.node_key, next_round.pruned_before,
          "the final fan exceeds the keep-recent budget, so all earlier results clear"
        entries = round_request_entries(next_round)
        calls = entries.select { |entry| entry["type"] == "tool_call_item" }
        results = entries.select { |entry| entry["type"] == "tool_result_item" }
        assert_equal expected_calls, calls.length
        assert_equal calls.map { |entry| entry.dig("payload", "call_id") },
          results.map { |entry| entry.dig("payload", "call_id") }
        assert results.all? { |entry| entry.dig("payload", "output") == AgentRuns::RoundReplay::Pairing::CLEARED }
        raise ActiveRecord::Rollback
      end
      clear_enqueued_jobs
      counts
    end

    def measure
      counts = { queries: 0, cache_hits: 0, rows: 0, cached_rows: 0, records: 0 }
      classes = Hash.new(0)
      sql_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA TRANSACTION])

        counts[payload[:cached] ? :cache_hits : :queries] += 1
        counts[payload[:cached] ? :cached_rows : :rows] += payload[:row_count].to_i
      end
      record_subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        count = payload.fetch(:record_count)
        counts[:records] += count
        classes[payload.fetch(:class_name)] += count
      end
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      counts.merge(elapsed_ms: (elapsed * 1_000).round(3),
        allocations: GC.stat(:total_allocated_objects) - allocated, record_classes: classes)
    ensure
      ActiveSupport::Notifications.unsubscribe(sql_subscriber)
      ActiveSupport::Notifications.unsubscribe(record_subscriber)
    end
end
