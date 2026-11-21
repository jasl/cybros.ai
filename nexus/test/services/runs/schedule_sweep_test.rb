require "test_helper"

class Runs::ScheduleSweepTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing
  include RunLaneTestHelper
  include InvocationHarness

  test "both recovery sources stop at their indexed window above retained history" do
    now = Time.current
    common = { account_id: accounts(:cybros).id, workspace_id: workspaces(:shared).id,
      creating_user_id: users(:member).id, approval_mode: "bypass", created_at: now, updated_at: now }
    Run.insert_all!(Array.new(4_000) { common.merge(status: "completed") })
    live_ids = Run.insert_all!(Array.new(600) do |index|
      common.merge(status: Run::LIVE_STATUSES[index % Run::LIVE_STATUSES.length])
    end, returning: %w[id]).rows.flatten
    node_common = { account_id: accounts(:cybros).id, run_id: live_ids.first,
      type: Tasks::ToolTask.sti_name, status: "completed", authored_by: "kernel",
      created_at: now, updated_at: now }
    Task.insert_all!(Array.new(10_000) do |index|
      node_common.merge(node_key: "history_#{index}", detached: false)
    end)
    Task.insert_all!(Array.new(600) do |index|
      node_common.merge(node_key: "pending_#{index}", detached: true)
    end)
    analyze_sources

    sources = capture_sources do
      Runs::ScheduleReady.stub(:call, nil) do
        result = Runs::ScheduleSweep.call
        assert_equal 400, result[:scanned]
        assert_equal [live_ids[199], Task.find_by!(node_key: "pending_199").id], result.cursor
      end
    end
    assert_equal 2, sources.length
    indexes = %w[index_runs_stop_frontier index_tasks_result_delivery_frontier]
    sources.zip(indexes).each do |source, index|
      plan = explain(*source)
      assert_window_plan(plan, index)
      assert_match(/actual [^\n]*rows=200(?:\.0+)? loops=1/, plan)
    end

    Run.where(id: live_ids).update_all(status: "completed")
    Task.where(detached: true).update_all(result_delivered_at: now)
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
      Run.create!(workspace: workspaces(:shared), creating_user: users(:member),
        approval_mode: "bypass", status: "running")
    end
    visited = []
    Runs::ScheduleReady.stub(:call, ->(run_id:) { visited << run_id }) do
      first = Runs::ScheduleSweep.call(batch: 2)
      assert_equal 2, first[:scanned]
      assert_equal [loops.second.id, nil], first.cursor
      assert_predicate first, :more?
      second = Runs::ScheduleSweep.call(schedule_after_id: first.cursor.first,
        result_delivery_after_id: first.cursor.last, batch: 2)
      assert_equal 1, second[:scanned]
      assert_equal [nil, nil], second.cursor
      assert_not_predicate second, :more?
    end
    assert_equal loops.map(&:id), visited
  end

  test "a poison schedule row does not fence later work or the continuation" do
    loops = Array.new(2) do
      Run.create!(workspace: workspaces(:shared), creating_user: users(:member),
        approval_mode: "bypass", status: "running")
    end
    visited = []
    errors = []
    advance = ->(run_id:) do
      visited << run_id
      raise IOError, "schedule interrupted" if run_id == loops.first.id
    end
    Rails.error.stub(:report, ->(error, **) { errors << error }) do
      Runs::ScheduleReady.stub(:call, advance) do
        result = Runs::ScheduleSweep.call(batch: 2)
        assert_equal [loops.last.id, nil], result.cursor
        assert_predicate result, :more?
      end
    end
    assert_equal loops.map(&:id), visited
    assert_equal ["schedule interrupted"], errors.map(&:message)
  end

  test "authorized pending paused and held loops are checked without dispatch or state changes" do
    loops = idle_loops
    snapshots = loops.to_h { |run| [run.id, run.attributes] }
    tasks = loops.map { |run| run.tasks.sole }

    assert_no_difference -> { ModelInvocation.count } do
      Runs::ScheduleSweep.call
    end

    loops.each { |run| assert_equal snapshots.fetch(run.id), run.reload.attributes }
    assert_equal %w[queued queued queued], tasks.map { |task| task.reload.status }
  end

  test "the recovery floor cancels pending paused and held loops after workspace authority is cut" do
    loops = idle_loops
    workspace = workspaces(:shared)
    workspace.with_lock { workspace.accept_archive }

    Runs::ScheduleSweep.call

    loops.each do |run|
      assert_equal "canceled", run.reload.status
      assert_equal "canceled", run.tasks.sole.status
    end
    assert_nil loops.first.canceling_since, "unstarted work never enters a drain"
    assert_equal %w[authority_lost authority_lost], loops.drop(1).map(&:failure_reason)
    assert_equal 0, ModelInvocation.count
  end

  test "a private workspace cuts parked work by creator and steward while its owner's work can resume" do
    workspace = workspaces(:shared)
    owner, member, agent = users(:owner, :member, :agent)
    outside_agent = create_agent_member(steward: member)
    conversation = Conversation.create!(workspace: workspace, creating_user: member, answering_user: agent)
    spoken = create_run_backed_turn(conversation: conversation, acting_user: member).run
    outsider, retained = [outside_agent, agent].map do |creator|
      Run.create!(workspace: workspace, creating_user: creator, approval_mode: "bypass", status: "running")
    end
    [spoken, outsider, retained].each { |run| grow!(run, ask("gate"), ask("next")) }
    [spoken, outsider, retained].each { |run| Runs::ScheduleJob.perform_now(run.id) }
    assert_equal %w[dispatched dispatched dispatched], [spoken, outsider, retained].map { |run| loop_node(run, "gate").status }

    result = Workspaces::UpdateAccessMode.call(workspace: workspace, by: owner, to: "private",
      lock_version: workspace.lock_version)
    assert_equal :updated, result.outcome
    clear_enqueued_jobs
    Runs::ScheduleSweepJob.perform_now

    [spoken, outsider].each do |run|
      assert_equal %w[canceled authority_lost], run.reload.values_at(:status, :failure_reason)
      assert_equal %w[canceled canceled], run.tasks.order(:id).pluck(:status)
    end
    assert_equal "running", retained.reload.status
    gate = loop_node(retained, "gate")
    assert_equal "dispatched", gate.status
    assert_equal "queued", loop_node(retained, "next").status
    assert_predicate Runs::Parks::Settle.call(node: gate, claim_token: gate.resolution_token,
      outcome: "completed", content: "approved"), :applied?
    clear_enqueued_jobs
    Runs::ScheduleSweepJob.perform_now
    assert_equal "dispatched", loop_node(retained, "next").status
  end

  test "a paged sweep reaches a paused descendant of a stopped ancestor after all stop hints are lost" do
    @account = accounts(:cybros)
    @human = users(:member)
    workspace = workspaces(:shared)
    agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(agent)
    source_room, middle_room, last_room = Array.new(3) do
      Conversation.create!(workspace: workspace, creating_user: @human, answering_user: agent)
    end
    independent = Run.create!(workspace: workspace, creating_user: @human, approval_mode: "bypass", status: "paused")
    _, source = materialize_loop_reply!(source_room, agent: @human)
    schedule_loop!(source)
    run_loop_round!(source, sse_success("first answer"))
    middle = materialize_result(source, middle_room)
    schedule_loop!(middle)
    run_loop_round!(middle, sse_success("second answer"))
    descendant = materialize_result(middle, last_room)
    assert_predicate Runs::Pause.call(Runs::Pause::Command.graceful(run: descendant, acting_user: @human)), :accepted?
    assert_predicate Runs::Stop.stop_now(source), :accepted?
    clear_enqueued_jobs

    stub_const(Runs::ScheduleSweep, :BATCH, 1) do
      perform_enqueued_jobs(only: Runs::ScheduleSweepJob) { Runs::ScheduleSweepJob.perform_now }
    end

    assert_equal "paused", independent.reload.status
    assert_equal "completed", middle.reload.status
    assert_equal "canceled", descendant.reload.status
    assert_equal "canceled", descendant.tasks.sole.status
  end

  test "a workspace restored after discovery preserves its unstarted Run while other ready work advances" do
    workspace = workspaces(:shared)
    owner = users(:owner)
    member = users(:member)
    unstarted, waiting, ready = [member, owner, owner].map do |creator|
      seed(ask("gate"), workspace: workspace, creating_user: creator, default_runner_executor_public_id: nil)
    end
    [waiting, ready].each do |run|
      assert_predicate Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: owner)), :accepted?
    end
    Runs::ScheduleJob.perform_now(waiting.id)
    gate = loop_node(waiting, "gate")
    assert_equal "dispatched", gate.status
    started_at = gate.started_at
    assert_equal :updated, Workspaces::UpdateAccessMode.call(workspace: workspace, by: owner,
      to: "private", lock_version: workspace.lock_version).outcome
    clear_enqueued_jobs

    restored = nil
    schedule = Runs::ScheduleReady.method(:call)
    before_lock = ->(run_id:) do
      if run_id == unstarted.id
        restored = Workspaces::UpdateAccessMode.call(workspace: workspace, by: owner,
          to: "account_wide", lock_version: workspace.reload.lock_version).outcome
      end
      schedule.call(run_id: run_id)
    end
    Runs::ScheduleReady.stub(:call, before_lock) { Runs::ScheduleSweepJob.perform_now }

    assert_equal :updated, restored, "the revoked Run was selected before the workspace reopened"
    assert_equal "pending", unstarted.reload.status
    assert_equal "queued", unstarted.tasks.sole.status
    assert_equal ["dispatched", started_at], gate.reload.values_at(:status, :started_at)
    assert_equal "dispatched", ready.tasks.sole.status
  end

  private

    def materialize_result(source, target)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
        host: target, acting_user: @human, entries: [{ "text" => "Background result." }],
        origin: Input::TASK_RESULT_ORIGIN, sender_conversation_public_id: source.conversation.public_id,
        run_public_id: source.public_id, task_key: "background", kind: "direct_reply",
        provider_id: "dev", model_ref: "mock-text"))
      assert_predicate result, :accepted?
      turn = Conversations::Inputs::ApplyNext.call(conversation_id: target.id)
      assert_predicate turn, :accepted?
      turn.value.active_variant.run
    end

    def idle_loops
      %w[pending paused needs_attention].map do |status|
        Run.create!(workspace: workspaces(:shared), creating_user: users(:member),
          approval_mode: "bypass", status: status,
          paused_at: (Time.current if status == "paused"),
          attention_reason: ("halt_failure" if status == "needs_attention")).tap do |run|
          run.tasks.create!(type: Tasks::ToolTask.sti_name,
            node_key: "unstarted", tool_name: "read_file", authored_by: "kernel")
        end
      end
    end

    def analyze_sources
      ApplicationRecord.lease_connection.execute("ANALYZE runs")
      ApplicationRecord.lease_connection.execute("ANALYZE tasks")
    end

    def capture_sources
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        next if payload[:cached]
        next unless sql.match?(/ORDER BY "(?:runs|tasks)"\."id" ASC LIMIT/)

        if sql.start_with?('SELECT "runs"."id"') ||
            sql.start_with?('SELECT "tasks"."id", "tasks"."run_id"')
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
