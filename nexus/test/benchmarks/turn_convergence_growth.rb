require "test_helper"
require_relative "../test_helpers/turn_convergence_test_helper"

# Run explicitly: PARALLEL_WORKERS=1 bin/rails test test/benchmarks/turn_convergence_growth.rb
# Healthy running pairs qualify for no convergence arm. The transaction rolls
# back the synthetic corpus; setup, warmup and EXPLAIN are outside timed samples.
class TurnConvergenceGrowthBenchmark < ActiveSupport::TestCase
  include TurnConvergenceTestHelper

  test "measure the actual convergence frontiers over healthy running pairs" do
    populated = 0
    [1_000, 10_000].each do |size|
      seed_running_pairs(size - populated)
      populated = size
      connection = ApplicationRecord.lease_connection
      connection.execute("ANALYZE conversations, conversation_turns, conversation_turn_variants, agent_runs")
      Conversations::Turns::Converge.call(batch: 200)

      queries = []
      samples = 3.times.map { measure(queries) }
      puts JSON.generate(operation: "turn_convergence", running_pairs: size, samples: samples)
      queries.uniq { |query| query.fetch(:sql) }.each_with_index do |query, index|
        plan = connection.select_value(
          "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{query.fetch(:sql)}", "EXPLAIN", query.fetch(:binds)
        )
        puts JSON.generate(operation: "turn_convergence_plan", running_pairs: size, query: index,
          sql: query.fetch(:sql), binds: connection.send(:type_casted_binds, query.fetch(:binds)), plan: JSON.parse(plan))
      end
    end
  end

  private

    def measure(queries)
      counts = { queries: 0, rows: 0 }
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA TRANSACTION CACHE])

        counts[:queries] += 1
        counts[:rows] += payload[:row_count].to_i
        if payload[:sql].start_with?("SELECT")
          queries << { sql: payload.fetch(:sql).dup, binds: payload.fetch(:binds).dup }
        end
      end
      GC.start
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ApplicationRecord.uncached { Conversations::Turns::Converge.call(batch: 200) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_predicate result, :accepted?
      assert_equal 0, result.value[:recorded], "healthy running pairs owe no timeline update"
      counts.merge(scanned: result.value[:scanned], elapsed_ms: (elapsed * 1_000).round(3),
        allocations: GC.stat(:total_allocated_objects) - allocated)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
