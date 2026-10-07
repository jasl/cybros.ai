require "test_helper"
require_relative "task_operation_growth_metrics"

# Explicit diagnostic: PARALLEL_WORKERS=1 bin/rails test \
#   test/benchmarks/operation_finalization_growth.rb
# Submit creates real operation/child shapes. Fixture completion skips child IO
# and handler execution; this measures ownership SQL and final publication, not runner growth.
class OperationFinalizationGrowthBenchmark < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RunLaneTestHelper

  WIDTH = 1_000
  PROBE_WIDTH = 10

  test "explain ownership and finalize one thousand observed children" do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @runner = suite_runner
    @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }])
    @loop = seed(tool("program", "program", "route" => { "kind" => "runner" }, "timeout_ms" => 3_600_000,
      "model_defaults" => { "tools" => fixture_runner_declarations([RunLaneTestHelper::READ_TOOL]), "model" => { "model" => "dev/mock-text" } }))
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: @loop, acting_user: @human)), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    @parent = @loop.agent_run_tasks.sole
    claim_parent
    prepare_children

    ApplicationRecord.with_connection do |connection|
      keys = @loop.agent_run_tasks.where(expansion_parent_id: @parent.id).order(:id).pluck(:node_key)
      assert_equal WIDTH, keys.length
      sql = ownership_sql(connection, keys)
      old_sql = sql.sub("released(parent_id, child_key) AS MATERIALIZED (", "released(parent_id, child_key) AS (")
      materialized_sql = old_sql.sub("released(parent_id, child_key) AS (", "released(parent_id, child_key) AS MATERIALIZED (")
      probe = ownership_sql(connection, keys.first(PROBE_WIDTH))
        .sub("released(parent_id, child_key) AS MATERIALIZED (", "released(parent_id, child_key) AS (")
      plans = {
        original_full: explain(connection, old_sql),
        original_probe: explain(connection, probe, analyze: true),
        materialized_full: explain(connection, materialized_sql, analyze: true),
        standing: [1, PROBE_WIDTH, WIDTH].map do |count|
          { keys: count, plan: explain(connection, standing_sql(connection, keys.first(count)), analyze: true) }
        end,
        observation: @observation_plans,
      }
      reads = [1, PROBE_WIDTH, WIDTH].map do |count|
        current = ownership_sql(connection, keys.first(count))
          .sub("released(parent_id, child_key) AS MATERIALIZED (", "released(parent_id, child_key) AS (")
        candidate = current.sub("released(parent_id, child_key) AS (", "released(parent_id, child_key) AS MATERIALIZED (")
        old_rows, old_ms = read_rows(connection, current)
        new_rows, new_ms = read_rows(connection, candidate)
        assert_equal old_rows, new_rows
        assert_equal keys.first(count).sort.map { |key| [key, @parent.node_key] }, new_rows
        { keys: count, original_ms: old_ms, materialized_ms: new_ms, identical_rows: new_rows.length }
      end
      connection.execute("ANALYZE agent_run_tasks")
      connection.execute("ANALYZE agent_run_edges")
      connection.execute("ANALYZE agent_run_task_operations")
      plans[:standing_after_analyze] = [1, PROBE_WIDTH, WIDTH].map do |count|
        { keys: count, plan: explain(connection, standing_sql(connection, keys.first(count)), analyze: true) }
      end
      puts JSON.generate(benchmark: "operation_finalization_plan", width: WIDTH, probe_width: PROBE_WIDTH,
        plan_only: ENV["FINALIZATION_PLAN_ONLY"] == "1", reads: reads, plans: plans)
      $stdout.flush

      unless ENV["FINALIZATION_PLAN_ONLY"] == "1"
        metrics = TaskOperationGrowthMetrics.new
        metrics.capture(:http_final) do
          post "/agent_api/v1/executor/inbox/#{@loop.public_id}/#{@parent.node_key}/commit",
            params: { claim_token: @parent.claim_token, content: "done", structured_content: WIDTH },
            headers: { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }, as: :json
        end
        puts JSON.generate(benchmark: "operation_finalization_commit", width: WIDTH,
          status: response.status, phases: metrics.summary)
        assert_response :success
        assert_equal "completed", @parent.reload.status
        assert @parent.committed_result_digest
        assert_equal WIDTH, @parent.task_operations.where.not(observed_position: nil).count
      end
    ensure
      metrics&.close
    end
  end

  private

    def claim_parent
      claim = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: @loop, task_key: @parent.node_key, executor: @runner))
      assert_predicate claim, :accepted?, claim.outcome.inspect
      @parent = claim.value
    end

    def prepare_children
      WIDTH.times do |index|
        access = Executors::TaskOperations::Access.new(agent_run: @loop, task_key: @parent.node_key,
          executor: @runner, claim_token: @parent.claim_token)
        result = Executors::TaskOperations::Submit.new(access: access, key: "op_#{index}",
          request: { "kind" => "tool", "name" => "read_file", "input" => { "index" => index } }).call
        assert_predicate result, :accepted?, result.outcome.inspect
        assert_nil result.value.dig("operation", "refusal")
      end
      @loop.with_lock do
        @observation_plans = [observation_plan("pending")]
        @loop.agent_run_tasks.where(expansion_parent_id: @parent.id).order(:id).last
          .update_columns(status: "completed", completed_at: Time.current)
        @observation_plans << observation_plan("one_ready")
        @loop.agent_run_tasks.where(expansion_parent_id: @parent.id).update_all(status: "completed", completed_at: Time.current)
        @observation_plans << observation_plan("all_ready")
        Executors::TaskOperations::Observation.pending(@parent).to_a.reverse_each.with_index do |candidate, index|
          assert_predicate candidate, :ready?
          Executors::TaskOperations::Observation.record(candidate, position: WIDTH + index + 1)
        end
      end
    end

    def observation_plan(state)
      query = nil
      capture = lambda do |*, payload|
        if payload.fetch(:sql).include?("jsonb_array_elements_text(response")
          query = [payload.fetch(:sql).dup, payload.fetch(:binds).dup]
        end
      end
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        Executors::TaskOperations::Observation.pending(@parent).first
      end
      sql, binds = query
      ApplicationRecord.with_connection do |connection|
        plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds)
        { state: state, plan: JSON.parse(plan) }
      end
    end

    def ownership_sql(connection, keys)
      query = nil
      connection.stub(:select_rows, ->(sql) { query = sql; [] }) do
        AgentRuns::ExpansionOwnership.operation_owners(@loop, keys)
      end
      query
    end

    def standing_sql(connection, keys)
      query = nil
      connection.stub(:select_rows, ->(sql) { query = sql; [] }) do
        AgentRuns::ExpansionOwnership.standing(@loop, keys)
      end
      query
    end

    def explain(connection, sql, analyze: false)
      options = analyze ? "ANALYZE, BUFFERS, FORMAT JSON" : "FORMAT JSON"
      JSON.parse(connection.select_value("EXPLAIN (#{options}) #{sql}"))
    end

    def read_rows(connection, sql)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rows = connection.select_rows(sql)
      [rows, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(3)]
    end
end
