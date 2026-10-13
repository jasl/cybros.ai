require "test_helper"

class AgentRuns::DrainSweepTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
  end

  test "the default pass visits at most 200 retained canceling loops" do
    ids = retained_loops(201)

    result = AgentRuns::DrainSweep.call

    assert_equal 200, result[:scanned],
      "waiting drains remain in the source and must still consume a bounded scan budget"
    assert_equal 0, result[:escalated]
    assert_equal ids[199], result.cursor
    assert_predicate result, :more?
    assert_equal 201, AgentRun.where(id: ids, status: "canceling").count
    assert_equal 201, AgentRunTask.where(agent_run_id: ids, status: "dispatched").count
  end

  test "continuation passes retained drains and reaches an overdue loop on the final page" do
    loops = Array.new(3) { gracefully_stopped_loop }
    loops.last.update_columns(canceling_since: (AgentRuns::DrainSweep::HARD_LIMIT + 1.minute).ago)

    first = AgentRuns::DrainSweep.call(batch: 2)
    assert_equal 2, first[:scanned]
    assert_equal 0, first[:escalated]
    assert_equal loops.second.id, first.cursor
    assert_predicate first, :more?
    assert_equal %w[canceling canceling canceling], loops.map { |agent_run| agent_run.reload.status }

    second = AgentRuns::DrainSweep.call(batch: 2, after_id: first.cursor)
    assert_equal 1, second[:scanned]
    assert_equal 1, second[:escalated]
    assert_equal loops.last.id, second.cursor
    assert_not_predicate second, :more?
    assert_equal %w[canceling canceling canceled], loops.map { |agent_run| agent_run.reload.status }
    assert_equal %w[dispatched dispatched canceled], loops.map { |agent_run| agent_run.agent_run_tasks.sole.status }
  end

  test "an exactly full final window ends at one empty continuation" do
    ids = retained_loops(2)

    first = AgentRuns::DrainSweep.call(batch: 2)
    assert_predicate first, :more?
    assert_equal ids.last, first.cursor

    last = AgentRuns::DrainSweep.call(batch: 2, after_id: first.cursor)
    assert_equal 0, last[:scanned]
    assert_equal 0, last[:escalated]
    assert_equal ids.last, last.cursor
    assert_not_predicate last, :more?

    next_wake = AgentRuns::DrainSweep.call(batch: 2)
    assert_equal 2, next_wake[:scanned], "the next recurring wake revisits retained drains"
  end

  test "a failing drain consumes its position without fencing the next page" do
    ids = retained_loops(3)
    visited = []
    errors = []
    evaluate = AgentRuns::EvaluateQuiescence.method(:call)
    failing = ->(agent_run) do
      visited << agent_run.id
      raise IOError, "drain interrupted" if agent_run.id == ids.first

      evaluate.call(agent_run)
    end

    Rails.error.stub(:report, ->(error, **) { errors << error.message }) do
      AgentRuns::EvaluateQuiescence.stub(:call, failing) do
        first = AgentRuns::DrainSweep.call(batch: 2)
        assert_equal 2, first[:scanned]
        assert_equal ids.second, first.cursor
        assert_predicate first, :more?
        last = AgentRuns::DrainSweep.call(batch: 2, after_id: first.cursor)
        assert_equal 1, last[:scanned]
        assert_not_predicate last, :more?
      end
    end

    assert_equal ids, visited
    assert_equal ["drain interrupted"], errors
    assert_equal 3, AgentRun.where(id: ids, status: "canceling").count
  end

  test "the production source enters an ordered bounded index above other live and terminal loops" do
    now = Time.current
    common = loop_attributes(now)
    AgentRun.insert_all!(Array.new(4_000) { common.merge(status: "completed", completed_at: now) })
    AgentRun.insert_all!(Array.new(4_000) { common.merge(status: "running") })
    ids = retained_loops(600)
    ApplicationRecord.lease_connection.execute("ANALYZE agent_runs")

    first = nil
    sources = [capture_source { first = AgentRuns::DrainSweep.call }]
    assert_equal 200, first[:scanned]
    assert_equal ids[199], first.cursor
    sources << capture_source do
      second = AgentRuns::DrainSweep.call(after_id: first.cursor)
      assert_equal 200, second[:scanned]
      assert_equal ids[399], second.cursor
    end
    sources.each do |source|
      plan = explain(source)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using index_agent_runs_drain_frontier/, plan)
      assert_no_match(/Seq Scan|Bitmap|Sort|Filter:/, plan,
        "a LIMIT after inspecting unrelated loops does not bound source discovery")
      assert_match(/actual [^\n]*rows=200(?:\.0+)? loops=1/, plan)
    end

    AgentRun.where(status: "canceling").update_all(status: "canceled", completed_at: now)
    ApplicationRecord.lease_connection.execute("ANALYZE agent_runs")
    sources.each do |source|
      empty = explain(source)
      assert_match(/Index(?: Only)? Scan/, empty)
      assert_no_match(/Seq Scan|Bitmap|Rows Removed by Filter/, empty)
      assert_match(/actual [^\n]*rows=0(?:\.0+)? loops=1/, empty,
        "the next empty source must not walk the unrelated running or terminal corpus")
    end
  end

  private

    def gracefully_stopped_loop
      agent_run = seed(ask("waiting"))
      started = AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: @human
      ))
      assert_predicate started, :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
        agent_run: agent_run, acting_user: @human, force: false
      ))
      assert_predicate stopped, :accepted?
      assert_equal "canceling", agent_run.reload.status
      assert_equal "dispatched", agent_run.agent_run_tasks.sole.status
      clear_enqueued_jobs
      agent_run
    end

    # Bulk setup reproduces the retained shape of the real graceful-stop flow
    # above without making scan measurements include hundreds of authoring calls.
    def retained_loops(count)
      now = Time.current
      ids = AgentRun.insert_all!(Array.new(count) do
        loop_attributes(now).merge(status: "canceling", canceling_since: now)
      end, returning: %w[id]).rows.flatten
      AgentRunTask.insert_all!(ids.map do |agent_run_id|
        { account_id: @account.id, agent_run_id: agent_run_id,
          type: AgentRunTasks::AwaitTask.sti_name, node_key: "waiting", status: "dispatched",
          authored_by: "author", resolution_token: SecureRandom.hex(32),
          await_started_at: now, started_at: now,
          await_timeout_ms: AgentRunTasks::AwaitTask::DEFAULT_TIMEOUT_MS,
          created_at: now, updated_at: now }
      end)
      ids
    end

    def loop_attributes(now)
      { account_id: @account.id, workspace_id: @workspace.id, creating_user_id: @human.id,
        approval_mode: "bypass", started_at: now, created_at: now, updated_at: now }
    end

    def capture_source
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:cached] || !payload[:sql].start_with?('SELECT "agent_runs"."id"')

        sources << [payload[:sql].dup, payload.fetch(:binds).dup]
      end
      begin
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      sources.sole
    end

    def explain(source)
      sql, binds = source
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}",
        "EXPLAIN", binds).join("\n")
    end
end
