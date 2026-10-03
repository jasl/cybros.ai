require "test_helper"

class AgentLoops::ParkRecoveryTest < ActiveJob::TestCase
  setup do
    @human = users(:owner)
    @workspace = workspaces(:shared)
  end

  test "retained parks consume the page and cannot hide later expiry or executor removal" do
    paused = start_park
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: paused.agent_loop, acting_user: @human
    )), :accepted?
    future = start_park
    runner = runner_for(users(:owner))
    withdrawn = start_park(runner: runner)
    expired = start_park
    expired.update_columns(await_started_at: 2.hours.ago)
    interrupt_revoke(runner)

    first = AgentLoops::Parks::TimeoutSweep.call(budget: 2)
    assert_equal [2, 0, 0], first.counts.values_at(:scanned, :expired, :revoked)
    assert_equal future.id, first.cursor
    assert_predicate first, :more?
    second = AgentLoops::Parks::TimeoutSweep.call(after_id: first.cursor, budget: 2)
    assert_equal [2, 1, 1], second.counts.values_at(:scanned, :expired, :revoked)
    assert_equal %w[failed executor_revoked], withdrawn.reload.values_at(:status, :error_key)
    assert_equal "timed_out", expired.reload.status
    assert_equal %w[dispatched dispatched], [paused.reload.status, future.reload.status]
    assert_not_predicate AgentLoops::Parks::TimeoutSweep.call(after_id: second.cursor, budget: 2), :more?
  end

  test "Human shutdown keeps its generation pending until every addressed page is cleared" do
    manager = users(:member)
    assert_equal :role_changed, manager.change_role(to: :admin)
    runner = runner_for(manager)
    agent_loop = seed(parallel(*3.times.map { |i| tool("read#{i}", "read_file", "on_failure" => "absorb") }), model("after"),
      runner_executor_public_id: runner.public_id)
    start_loop(agent_loop)
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    epoch = runner.credential_epoch
    assert_equal :removed, manager.remove
    assert_equal :restored, manager.restore

    TaskExecutor.converge
    assert_equal epoch, runner.reload.credential_epoch
    assert_predicate runner, :shutdown_pending?
    assert_equal 3, agent_loop.agent_loop_nodes.where(status: "dispatched").count
    first = AgentLoops::Parks::TimeoutSweep.call(budget: 2)
    assert_equal [2, 2], first.counts.values_at(:scanned, :revoked)
    TaskExecutor.converge
    assert_equal epoch, runner.reload.credential_epoch, "one addressed park still owns the episode"
    second = AgentLoops::Parks::TimeoutSweep.call(after_id: first.cursor, budget: 2)
    assert_equal [1, 1], second.counts.values_at(:scanned, :revoked)
    TaskExecutor.converge
    assert_equal epoch + 1, runner.reload.credential_epoch
    assert_not_predicate runner, :shutdown_pending?
    assert_equal 3, agent_loop.agent_loop_nodes.where(error_key: "executor_revoked").count
  end

  test "a handoff after discovery protects the newly addressed park" do
    old = runner_for(users(:owner))
    park = start_park(runner: old)
    interrupt_revoke(old)
    replacement = suite_runner
    sweep = AgentLoops::Parks::TimeoutSweep.new
    discover = sweep.method(:removed_addressees)
    sweep.stub(:removed_addressees, ->(ids) {
      found = discover.call(ids)
      assert_equal [park.id], found.map(&:id)
      assert_predicate Executors::Handoff.call(Executors::Handoff::Command.new(
        host: park.agent_loop, executor_public_id: replacement.public_id, acting_user: @human
      )), :accepted?
      found
    }) do
      result = sweep.call
      assert_equal [0, 0], result.counts.values_at(:expired, :revoked)
    end
    assert_equal ["dispatched", replacement.id], park.reload.values_at(:status, :addressed_executor_id)
  end

  test "a failed removal advances the cursor and the next periodic pass retries it" do
    runner = runner_for(users(:owner))
    first = start_park(runner: runner)
    second = start_park(runner: runner)
    interrupt_revoke(runner)
    apply = AgentLoops::Parks::Revoke.method(:call)
    AgentLoops::Parks::Revoke.stub(:call, ->(agent_loop:, node:) {
      raise IOError, "temporary removal failure" if node.id == first.id

      apply.call(agent_loop: agent_loop, node: node)
    }) do
      page = AgentLoops::Parks::TimeoutSweep.call(budget: 1)
      assert_equal [1, 0], page.counts.values_at(:scanned, :revoked)
      assert_equal first.id, page.cursor
      next_page = AgentLoops::Parks::TimeoutSweep.call(after_id: page.cursor, budget: 1)
      assert_equal 1, next_page[:revoked]
    end
    assert_equal "dispatched", first.reload.status
    assert_equal "failed", second.reload.status
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:revoked]
    assert_equal "failed", first.reload.status
  end

  test "the production source index stops at each page before clock and authority predicates" do
    park = start_park
    common = park.attributes.except("id", "node_key")
    AgentLoopNode.insert_all!(Array.new(10_000) do |i|
      common.merge("node_key" => "old#{i}", "status" => "completed")
    end)
    AgentLoopNode.insert_all!(Array.new(1_500) do |i|
      common.merge("node_key" => "waiting#{i}")
    end)
    ApplicationRecord.lease_connection.execute("ANALYZE agent_loop_nodes")
    sources = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      if !payload[:cached] && sql.start_with?('SELECT "agent_loop_nodes"."id" FROM "agent_loop_nodes"') &&
          sql.include?("LIMIT")
        sources << [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      first = AgentLoops::Parks::TimeoutSweep.call
      second = AgentLoops::Parks::TimeoutSweep.call(after_id: first.cursor)
      assert_equal [500, 500], [first[:scanned], second[:scanned]]
      assert_equal [0, 0], [first[:expired], second[:expired]]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 2, sources.length
    sources.each do |sql, binds|
      plan = ApplicationRecord.lease_connection.select_values(
        "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
      ).join("\n")
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using index_agent_loop_nodes_on_park_frontier/, plan)
      assert_no_match(/Seq Scan|Bitmap|Sort|Filter:/, plan)
      assert_match(/actual [^\n]*rows=500(?:\.0+)? loops=1/, plan)
    end
  end

  private

    def start_park(runner: suite_runner)
      agent_loop = seed(tool("read", "read_file"), runner_executor_public_id: runner.public_id)
      start_loop(agent_loop)
      agent_loop.agent_loop_nodes.find_by!(node_key: "read")
    end

    def start_loop(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def runner_for(manager)
      runner = connect_runner(manager: manager, runner_identifier: "removal-runner",
        assignment_scope: :account_wide).executor_access_token.task_executor
      assert_predicate runner.announce(tools: TEST_SERVED_TOOLS), :accepted?
      runner
    end

    def interrupt_revoke(runner)
      AgentLoops::Parks::TimeoutSweepJob.stub(:perform_later, -> { raise IOError, "revocation interrupted" }) do
        assert_raises(IOError) { runner.revoke }
      end
      assert_predicate runner.reload, :revoked?
    end
end
