require "test_helper"

class AgentRuns::ReleaseLoadingTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "recounting a waiting fan does not instantiate all its dependencies" do
    measurements = [4, 24].map do |width|
      agent_run = seed(parallel(*Array.new(width) { |index| ask("a#{index}") }), model("after"))
      started = AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate started, :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      settled = AgentRuns::Parks::Settle.call(
        node: agent_run.agent_run_tasks.find_by!(node_key: "a0"),
        trusted: true, content: "done", outcome: "completed"
      )
      assert_predicate settled, :applied?
      head = agent_run.agent_run_tasks.find_by!(node_key: "after")
      ready = nil
      measured = agent_run.with_lock do
        instantiated_records { ready = AgentRuns::Release.recompute(head) }
      end

      assert_empty ready
      assert_equal "queued", head.reload.status
      assert_equal width - 1, head.remaining_dependencies
      clear_enqueued_jobs
      measured
    end

    assert_operator measurements.last, :<=, measurements.first + 2,
      "dependency recounts must not materialize the whole fan for each completion: #{measurements.inspect}"
  end

  test "the recount queries its own dependencies beside unrelated graph history" do
    width = 24
    agent_run = seed(parallel(*Array.new(width) { |index| ask("a#{index}") }), model("after"))
    head = agent_run.agent_run_tasks.find_by!(node_key: "after")
    common = head.attributes.except("id", "public_id", "node_key").merge(
      "status" => "completed", "remaining_dependencies" => 0, "input_from_node_keys" => [],
      "completed_at" => Time.current
    )
    # Unrelated historical chains supply realistic table statistics, outside
    # the fan being recounted. No synthetic row participates in its result.
    loop_attributes = agent_run.attributes.except("id", "public_id").merge("deliverable_node_id" => nil)
    loops = AgentRun.insert_all!(Array.new(100) { loop_attributes.dup }, returning: [:id]).rows.flatten
    ids = AgentRunTask.insert_all!(Array.new(10_000) do |index|
      common.merge("node_key" => "history-#{index}", "agent_run_id" => loops.fetch(index / 100))
    end, returning: [:id]).rows.flatten
    AgentRunEdge.insert_all!(ids.each_slice(100).with_index.flat_map do |chain, index|
      chain.each_cons(2).map do |from, to|
        { account_id: @account.id, agent_run_id: loops.fetch(index), from_node_id: from, to_node_id: to }
      end
    end)
    connection = ApplicationRecord.lease_connection
    connection.execute("ANALYZE agent_run_tasks")
    connection.execute("ANALYZE agent_run_edges")

    statements = []
    capture = lambda do |*, payload|
      if !payload[:cached] && payload[:sql].include?("GROUP BY")
        statements << [payload.fetch(:sql).dup, payload.fetch(:binds).dup]
      end
    end
    agent_run.with_lock do
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        ApplicationRecord.uncached { AgentRuns::Release.recompute(head) }
      end
    end
    assert_equal width, head.reload.remaining_dependencies
    sql, binds = statements.sole
    result = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}", "EXPLAIN", binds)
    plan = JSON.parse(result).sole.fetch("Plan")
    message = JSON.pretty_generate(plan)
    assert_equal 1, plan.fetch("Actual Rows"), message
    scans = plan_nodes(plan).select do |part|
      %w[agent_run_tasks agent_run_edges].include?(part["Relation Name"])
    end
    assert_equal 2, scans.length, message
    scans.each do |scan|
      assert_operator scan.fetch("Actual Rows"), :<=, width, message
      assert scan.key?("Index Cond"), message
    end
  end

  private

    def plan_nodes(plan) = [plan] + Array(plan["Plans"]).flat_map { |child| plan_nodes(child) }

    def instantiated_records
      records = 0
      subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        records += payload.fetch(:record_count)
      end
      ApplicationRecord.uncached { yield }
      records
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
