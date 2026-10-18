require "test_helper"

class Runs::GraphLookupPlanTest < ActiveSupport::TestCase
  HISTORY_LOOPS = 2_000
  NODES_PER_LOOP = 10

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "graph reads and reclamation probes stay local beside retained execution history" do
    run = seed(model("first"), tool("call"), model("last"))
    nodes = run.tasks.order(:id).to_a
    invocations = nodes.select(&:model_task?).map do |node|
      invocation = completed_invocation(run, "task:#{node.id}:0")
      node.update_columns(selected_model_invocation_id: invocation.id)
      invocation
    end
    unselected = completed_invocation(run, "task:#{nodes.first.id}:1")
    run.tasks.update_all(status: "completed", remaining_dependencies: 0, completed_at: 100.days.ago)
    run.update!(status: "completed", completed_at: 100.days.ago)
    seed_history(run, nodes.first.reload, invocations.first)
    connection.execute("ANALYZE runs, tasks, run_edges, model_invocations")

    scalar = capture_edges do
      assert_equal nodes.first.id, Runs::KernelTool.round_of(nodes.fetch(1)).id
    end
    batched = capture_edges { Runs::Transition.created(run, nodes) }
    statements = [
      { name: "incoming scalar", sql: scalar.first, binds: scalar.last,
        table: "run_edges", column: "to_node_id", rows: 1 },
      { name: "incoming batch", sql: batched.first, binds: batched.last,
        table: "run_edges", column: "to_node_id", rows: 2 },
      reference_probe("run_edges", "to_node_id", nodes.first.id),
      reference_probe("runs", "deliverable_node_id", nodes.first.id),
      reference_probe("tasks", "selected_model_invocation_id", unselected.id),
    ]
    assert_lookup_plans(statements)

    run.update!(tombstoned_at: 100.days.ago)
    assert_equal 1, Runs::Reap.call(batch: 1)[:reaped]
    assert_not Run.exists?(run.id)
    assert_empty Task.where(id: nodes.map(&:id))
    assert_empty ModelInvocation.where(id: [*invocations.map(&:id), unselected.id])
    assert_equal HISTORY_LOOPS, Run.count
    assert_equal HISTORY_LOOPS * NODES_PER_LOOP, Task.count
    assert_equal HISTORY_LOOPS * (NODES_PER_LOOP - 1), RunEdge.count
  end

  private

    def completed_invocation(run, key)
      run.model_invocations.create!(creating_user: @human, internal_creation_key: key,
        provider_id: "dev", model_ref: "mock-text", admission_deadline_seconds: 60,
        status: "completed", terminal_at: 100.days.ago, terminal_event_recorded_at: 100.days.ago)
    end

    def seed_history(run, node, invocation)
      # Copy ordinary rows, including their inline snapshots. Thousands of
      # distinct retained loops prevent a skip scan over loop_id from looking
      # like an endpoint lookup merely because the fixture has few owners.
      loop_attributes = run.attributes.except("id", "public_id").merge("deliverable_node_id" => nil)
      node_attributes = node.attributes.except("id", "node_key")
      invocation_attributes = invocation.attributes.except("id", "public_id", "internal_creation_key")
      loops = Run.insert_all!(Array.new(HISTORY_LOOPS) { loop_attributes.dup }, returning: [:id]).rows.flatten
      loops.each_slice(250) do |loop_ids|
        owners = loop_ids.flat_map { |id| Array.new(NODES_PER_LOOP, id) }
        invocations = ModelInvocation.insert_all!(owners.each_with_index.map do |id, index|
          invocation_attributes.merge("run_id" => id, "internal_creation_key" => "history-#{id}-#{index}")
        end, returning: [:id]).rows.flatten
        nodes = Task.insert_all!(owners.each_with_index.map do |id, index|
          position = index % NODES_PER_LOOP
          node_attributes.merge("run_id" => id, "node_key" => "history-#{position}",
            "selected_model_invocation_id" => invocations.fetch(index),
            "input_from_node_keys" => (position.positive? ? ["history-#{position - 1}"] : []))
        end, returning: [:id]).rows.flatten
        RunEdge.insert_all!(nodes.each_slice(NODES_PER_LOOP).with_index.flat_map do |chain, index|
          chain.each_cons(2).map do |from, to|
            { account_id: @account.id, run_id: loop_ids.fetch(index), from_node_id: from, to_node_id: to }
          end
        end)
        connection.execute(<<~SQL)
          UPDATE runs SET deliverable_node_id = tasks.id
          FROM tasks
          WHERE tasks.run_id = runs.id
            AND runs.id IN (#{loop_ids.join(",")})
            AND tasks.node_key = 'history-#{NODES_PER_LOOP - 1}'
        SQL
      end
    end

    def capture_edges
      statements = []
      capture = lambda do |*, payload|
        if !payload[:cached] && payload[:sql].start_with?("SELECT") &&
            payload[:sql].include?('FROM "run_edges"')
          statements << [payload.fetch(:sql).dup, payload.fetch(:binds).dup]
        end
      end
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      statements.sole
    end

    def reference_probe(table, column, id)
      # PostgreSQL's delete-side RI check searches all referencing owners,
      # even after the reaper has removed this loop's own references. These
      # existing parent ids have no remaining reference, so the whole lookup
      # must finish; an early match cannot hide unrelated-history work.
      { name: "#{column} RI", table: table, column: column, rows: 0, binds: [], sql: <<~SQL }
        SELECT 1 FROM ONLY "public"."#{table}" x
        WHERE #{id}::bigint OPERATOR(pg_catalog.=) "#{column}" FOR KEY SHARE OF x
      SQL
    end

    def assert_lookup_plans(statements)
      statements.each do |statement|
        result = explain_lookup(statement)
        plan = result.fetch("Plan")
        message = "#{statement.fetch(:name)}: #{JSON.pretty_generate(result)}"
        scans = plan_nodes(plan).select { |part| part["Relation Name"] == statement.fetch(:table) }
        assert_equal statement.fetch(:rows), plan.fetch("Actual Rows"), message
        assert_not scans.empty?, message
        scans.each do |scan|
          assert_includes ["Index Scan", "Bitmap Heap Scan"], scan.fetch("Node Type"), message
          assert_operator scan.fetch("Actual Rows"), :<=, statement.fetch(:rows), message
          assert_equal 0, scan.fetch("Rows Removed by Filter", 0), message
        end
        index_name = "index_#{statement.fetch(:table)}_on_#{statement.fetch(:column)}"
        lookup = plan_nodes(plan).find { |part| part["Index Name"] == index_name }
        assert_not_nil lookup, message
        assert_includes lookup.fetch("Index Cond"), statement.fetch(:column), message
        assert_operator plan.fetch("Shared Hit Blocks") + plan.fetch("Shared Read Blocks"), :<=, 64, message
      end
    end

    def explain_lookup(statement)
      JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{statement.fetch(:sql)}",
        "EXPLAIN", statement.fetch(:binds))).sole
    end

    def plan_nodes(plan) = [plan] + Array(plan["Plans"]).flat_map { |child| plan_nodes(child) }

    def connection = ApplicationRecord.lease_connection
end
