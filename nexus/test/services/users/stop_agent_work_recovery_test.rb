require "test_helper"

class Users::StopAgentWorkRecoveryTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
  end

  test "retained work consumes the window and later removed work is reached on continuation" do
    retained = Array.new(3) { bare_loop(@human) }
    stopped = Array.new(2) { bare_loop(@agent) }
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs

    first = Users::StopAgentWork.call(batch: 2)
    assert_equal 2, first[:scanned]
    assert_equal 0, first[:loops_stopped]
    assert_equal({ conversation_after_id: nil, loop_after_id: retained.second.id }, first.cursor)
    second = Users::StopAgentWork.call(**first.cursor, batch: 2)
    assert_equal 2, second[:scanned]
    assert_equal 1, second[:loops_stopped]
    assert_equal({ conversation_after_id: nil, loop_after_id: stopped.first.id }, second.cursor)
    third = Users::StopAgentWork.call(**second.cursor, batch: 2)
    assert_equal 1, third[:scanned]
    assert_equal 1, third[:loops_stopped]
    assert_not_predicate third, :more?
    assert_equal ["pending"] * 3, retained.map { |agent_run| agent_run.reload.status }
    assert_equal ["canceled"] * 2, stopped.map { |agent_run| agent_run.reload.status }
  end

  test "a failed target does not hide later work and the next floor retries it" do
    failed = bare_loop(@agent)
    healthy = bare_loop(@agent)
    assert_equal :removed, @agent.remove
    clear_enqueued_jobs
    stop = AgentRuns::Stop.method(:stop_now)
    reports = []
    AgentRuns::Stop.stub(:stop_now, ->(agent_run) {
      raise IOError, "interrupted stop" if agent_run.id == failed.id

      stop.call(agent_run)
    }) do
      Rails.error.stub(:report, ->(_error, context:, **) { reports << context }) do
        first = Users::StopAgentWork.call(batch: 1)
        assert_equal failed.id, first.cursor.fetch(:loop_after_id)
        assert_equal 0, first[:loops_stopped]
        second = Users::StopAgentWork.call(**first.cursor, batch: 1)
        assert_equal 1, second[:loops_stopped]
      end
    end
    assert_equal "pending", failed.reload.status
    assert_equal "canceled", healthy.reload.status
    assert_equal failed.public_id, reports.sole.fetch(:run_public_id)
    assert_not reports.sole.key?(:agent_run_id)
    Users::StopAgentWorkJob.perform_now
    assert_equal "canceled", failed.reload.status
  end

  test "the job yields between full windows and parks its exhausted phase" do
    loops = Array.new(3) { bare_loop(@human) }
    clear_enqueued_jobs

    options = { batch: 2, conversation_after_id: nil, loop_after_id: loops.second.id }
    assert_enqueued_with(job: Users::StopAgentWorkJob, args: [nil, options]) do
      Users::StopAgentWorkJob.perform_now(nil, batch: 2)
    end
    clear_enqueued_jobs
    assert_no_enqueued_jobs(only: Users::StopAgentWorkJob) do
      Users::StopAgentWorkJob.perform_now(nil, options)
    end
    assert_equal ["pending"] * 3, loops.map { |agent_run| agent_run.reload.status }
  end

  test "both production sources stop on their live indexes before relationship filtering" do
    now = Time.current
    loop_common = { account_id: @account.id, workspace_id: @workspace.id,
      creating_user_id: @human.id, approval_mode: "bypass", created_at: now, updated_at: now }
    AgentRun.insert_all!(Array.new(4_000) { loop_common.merge(status: "completed") })
    live_ids = AgentRun.insert_all!(Array.new(600) { loop_common.merge(status: "pending") },
      returning: %w[id]).rows.flatten
    room_common = { account_id: @account.id, workspace_id: @workspace.id,
      creating_user_id: @human.id, answering_user_id: @human.id, last_activity_at: now, created_at: now, updated_at: now }
    rooms = Conversation.insert_all!(Array.new(4_600) { room_common }, returning: %w[id]).rows.flatten
    actor = Speakers::Resolve.member(account: @account, user: @human)
    turn_common = { account_id: @account.id, speaker_id: actor.id, control_owner_user_id: @human.id,
      answering_user_id: @human.id, kind: "direct_reply", role: "assistant", position: 0,
      created_at: now, updated_at: now }
    ConversationTurn.insert_all!(rooms.map.with_index do |id, index|
      turn_common.merge(conversation_id: id, status: index < 4_000 ? "completed" : "pending")
    end)
    analyze_sources

    sources = capture_sources do
      first = Users::StopAgentWork.call
      second = Users::StopAgentWork.call(**first.cursor)
      assert_equal [400, 400], [first[:scanned], second[:scanned]]
      assert_equal [0, 0], [first[:loops_stopped], second[:loops_stopped]]
      assert_equal live_ids[399], second.cursor.fetch(:loop_after_id)
    end
    assert_equal 4, sources.length
    sources.each do |sql, binds|
      index = sql.include?('FROM "conversation_turns"') ?
        "index_conversation_turns_one_active" : "index_agent_runs_stop_frontier"
      plan = explain(sql, binds)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using #{index}/, plan)
      assert_no_match(/Seq Scan|Bitmap|Sort|Filter:/, plan)
      assert_match(/actual [^\n]*rows=200(?:\.0+)? loops=1/, plan)
    end

    AgentRun.where(id: live_ids).update_all(status: "completed")
    ConversationTurn.where(conversation_id: rooms.last(600)).update_all(status: "completed")
    analyze_sources
    sources.each do |source|
      plan = explain(*source)
      assert_match(/Index(?: Only)? Scan/, plan)
      assert_no_match(/Seq Scan|Bitmap|Rows Removed by Filter/, plan)
      assert_match(/actual [^\n]*rows=0(?:\.0+)? loops=1/, plan)
    end
  end

  private

    def bare_loop(creator)
      AgentRun.create!(workspace: @workspace, creating_user: creator, approval_mode: "bypass")
    end

    def analyze_sources
      ApplicationRecord.lease_connection.execute("ANALYZE agent_runs")
      ApplicationRecord.lease_connection.execute("ANALYZE conversation_turns")
    end

    def capture_sources
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        if !payload[:cached] && sql.include?("LIMIT") &&
            (sql.start_with?('SELECT "conversation_turns"."conversation_id" FROM "conversation_turns"') ||
              sql.start_with?('SELECT "agent_runs"."id" FROM "agent_runs"'))
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
end
