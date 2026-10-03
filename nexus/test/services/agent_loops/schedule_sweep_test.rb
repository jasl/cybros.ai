require "test_helper"

class AgentLoops::ScheduleSweepTest < ActiveJob::TestCase
  test "both recovery sources stop at their indexed window above retained history" do
    now = Time.current
    common = { account_id: accounts(:cybros).id, workspace_id: workspaces(:shared).id,
      creating_user_id: users(:member).id, approval_mode: "bypass", created_at: now, updated_at: now }
    AgentLoop.insert_all!(Array.new(4_000) { common.merge(status: "completed") })
    live_ids = AgentLoop.insert_all!(Array.new(600) do |index|
      common.merge(status: AgentLoop::LIVE_STATUSES[index % AgentLoop::LIVE_STATUSES.length])
    end, returning: %w[id]).rows.flatten
    node_common = { account_id: accounts(:cybros).id, agent_loop_id: live_ids.first,
      type: AgentLoopNodes::ToolTask.sti_name, status: "completed", authored_by: "kernel",
      created_at: now, updated_at: now }
    AgentLoopNode.insert_all!(Array.new(10_000) do |index|
      node_common.merge(node_key: "history_#{index}", detached: false)
    end)
    AgentLoopNode.insert_all!(Array.new(600) do |index|
      node_common.merge(node_key: "pending_#{index}", detached: true)
    end)
    analyze_sources

    sources = capture_sources do
      AgentLoops::ScheduleReady.stub(:call, nil) do
        result = AgentLoops::ScheduleSweep.call
        assert_equal 400, result[:scanned]
        assert_equal [live_ids[199], AgentLoopNode.find_by!(node_key: "pending_199").id], result.cursor
      end
    end
    assert_equal 2, sources.length
    indexes = %w[index_agent_loops_stop_frontier index_agent_loop_nodes_mail_frontier]
    sources.zip(indexes).each do |source, index|
      plan = explain(*source)
      assert_window_plan(plan, index)
      assert_match(/actual [^\n]*rows=200(?:\.0+)? loops=1/, plan)
    end

    AgentLoop.where(id: live_ids).update_all(status: "completed")
    AgentLoopNode.where(detached: true).update_all(mailed_at: now)
    analyze_sources
    sources.each do |source|
      plan = explain(*source)
      # An empty status index may be cheaper than the id frontier; sorting
      # zero indexed matches is still an empty proof independent of history.
      assert_match(/Index(?: Only)? Scan/, plan)
      assert_no_match(/Seq Scan|Bitmap|Rows Removed by Filter/, plan)
      assert_match(/actual [^\n]*rows=0(?:\.0+)? loops=1/, plan,
        "an empty recovery frontier must not inspect ordinary retained history")
    end
  end

  test "a full schedule window carries its cursor while the empty mail phase stays parked" do
    loops = Array.new(3) do
      AgentLoop.create!(workspace: workspaces(:shared), creating_user: users(:member),
        approval_mode: "bypass", status: "running")
    end
    visited = []
    AgentLoops::ScheduleReady.stub(:call, ->(agent_loop_id:) { visited << agent_loop_id }) do
      first = AgentLoops::ScheduleSweep.call(batch: 2)
      assert_equal 2, first[:scanned]
      assert_equal [loops.second.id, nil], first.cursor
      assert_predicate first, :more?
      second = AgentLoops::ScheduleSweep.call(schedule_after_id: first.cursor.first,
        mail_after_id: first.cursor.last, batch: 2)
      assert_equal 1, second[:scanned]
      assert_equal [nil, nil], second.cursor
      assert_not_predicate second, :more?
    end
    assert_equal loops.map(&:id), visited
  end

  test "a poison schedule row does not fence later work or the continuation" do
    loops = Array.new(2) do
      AgentLoop.create!(workspace: workspaces(:shared), creating_user: users(:member),
        approval_mode: "bypass", status: "running")
    end
    visited = []
    errors = []
    advance = ->(agent_loop_id:) do
      visited << agent_loop_id
      raise IOError, "schedule interrupted" if agent_loop_id == loops.first.id
    end
    Rails.error.stub(:report, ->(error, **) { errors << error }) do
      AgentLoops::ScheduleReady.stub(:call, advance) do
        result = AgentLoops::ScheduleSweep.call(batch: 2)
        assert_equal [loops.last.id, nil], result.cursor
        assert_predicate result, :more?
      end
    end
    assert_equal loops.map(&:id), visited
    assert_equal ["schedule interrupted"], errors.map(&:message)
  end

  test "authorized pending paused and held loops are checked without dispatch or state changes" do
    loops = idle_loops
    snapshots = loops.to_h { |agent_loop| [agent_loop.id, agent_loop.attributes] }
    tasks = loops.map { |agent_loop| agent_loop.agent_loop_nodes.sole }

    assert_no_difference -> { ModelInvocation.count } do
      AgentLoops::ScheduleSweep.call
    end

    loops.each { |agent_loop| assert_equal snapshots.fetch(agent_loop.id), agent_loop.reload.attributes }
    assert_equal %w[queued queued queued], tasks.map { |task| task.reload.status }
  end

  test "the recovery floor cancels pending paused and held loops after workspace authority is cut" do
    loops = idle_loops
    workspace = workspaces(:shared)
    workspace.with_lock { workspace.accept_archive }

    AgentLoops::ScheduleSweep.call

    loops.each do |agent_loop|
      assert_equal "canceled", agent_loop.reload.status
      assert_equal "canceled", agent_loop.agent_loop_nodes.sole.status
    end
    assert_nil loops.first.canceling_since, "unstarted work never enters a drain"
    assert_equal %w[authority_lost authority_lost], loops.drop(1).map(&:failure_reason)
    assert_equal 0, ModelInvocation.count
  end

  private

    def idle_loops
      %w[pending paused needs_attention].map do |status|
        AgentLoop.create!(workspace: workspaces(:shared), creating_user: users(:member),
          approval_mode: "bypass", status: status,
          paused_at: (Time.current if status == "paused"),
          attention_reason: ("halt_failure" if status == "needs_attention")).tap do |agent_loop|
          agent_loop.agent_loop_nodes.create!(type: AgentLoopNodes::ToolTask.sti_name,
            node_key: "unstarted", tool_name: "read_file", authored_by: "kernel")
        end
      end
    end

    def analyze_sources
      ApplicationRecord.lease_connection.execute("ANALYZE agent_loops")
      ApplicationRecord.lease_connection.execute("ANALYZE agent_loop_nodes")
    end

    def capture_sources
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        next if payload[:cached]

        if sql.start_with?('SELECT "agent_loops"."id"') ||
            sql.start_with?('SELECT "agent_loop_nodes"."id", "agent_loop_nodes"."agent_loop_id"')
          sources << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      begin
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      sources
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}",
        "EXPLAIN", binds).join("\n")
    end

    def assert_window_plan(plan, index)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using #{index}/, plan)
      assert_no_match(/Seq Scan|Bitmap|Sort|Filter:/, plan)
    end
end
