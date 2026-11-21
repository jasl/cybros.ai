require "test_helper"

class Runs::ScheduleRecoveryCandidatesTest < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "admit queued work and settle its deliverable when both precise wakes are lost" do
    run = seed(ask("wait"))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    clear_enqueued_jobs
    assert_equal [run.id], candidates(run)
    Runs::ScheduleReady.call(run_id: run.id)
    refute_predicate run.reload, :delivered?
    assert_equal [], candidates(run), "the live token holder owns progress"

    run.with_lock do
      Runs::Transition.node(run.deliverable, status: "completed", completed_at: Time.current)
    end
    assert_equal [run.id], candidates(run)
    Runs::ScheduleReady.call(run_id: run.id)
    assert_predicate run.reload, :completed?
    assert_predicate run, :delivered?
    assert_equal [], candidates(run)
  end

  test "a foreground holder still allows ready work, observation, MCP, detached receipts and compaction recovery" do
    run = waiting_loop
    ready = task(run, "next", status: "queued", remaining_dependencies: 1)
    assert_equal [], candidates(run)
    ready.update_columns(remaining_dependencies: 0)
    assert_equal [run.id], candidates(run)
    ready.update_columns(status: "completed")

    observer = task(run, "observer", type: Tasks::AwaitTask.sti_name, status: "dispatched",
      awaited_run_public_id: run.public_id, awaited_task_key: "next", resolution_token: SecureRandom.hex)
    assert_equal [run.id], candidates(run)
    observer.update_columns(status: "completed")

    remote = task(run, "remote", status: "running", mcp_connection_public_id: mcp_connections(:notes).public_id)
    assert_equal [run.id], candidates(run)
    remote.update_columns(external_started_at: Time.current)
    assert_equal [], candidates(run), "a started external call cannot be redelivered"

    receipt = task(run, "tip", status: "completed", detached: true)
    assert_equal [run.id], candidates(run)
    receipt.update_columns(result_delivered_at: Time.current)
    assert_equal [], candidates(run)

    delegate = task(run, "compact", status: "timed_out", on_failure: "absorb")
    assert_equal [run.id], candidates(run)
    run.tasks.where(id: delegate.id).update_all(compaction: { Conversations::Compaction::Fallback::DELEGATE_FALLBACK => "replacement" })
    assert_equal [], candidates(run)
  end

  test "attention is reconciled while independent foreground work is running" do
    run = waiting_loop
    ask = task(run, "question", type: Tasks::AwaitTask.sti_name, status: "awaiting_input")
    assert_equal [run.id], candidates(run)
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal Runs::EvaluateQuiescence::ASKING_REASON, run.reload.attention_reason
    assert_equal [], candidates(run)

    ask.update_columns(status: "completed")
    hold = task(run, "approval", status: "needs_approval")
    assert_equal [run.id], candidates(run)
    Runs::ScheduleReady.call(run_id: run.id)
    assert_equal Runs::EvaluateQuiescence::APPROVAL_REASON, run.reload.attention_reason
    assert_equal [], candidates(run)
    hold.update_columns(status: "completed")
    assert_equal [run.id], candidates(run)
    Runs::ScheduleReady.call(run_id: run.id)
    assert_nil run.reload.attention_reason
    assert_equal [], candidates(run)
  end

  test "a sole foreground approval rests after announcement and keeps both authority and release recovery" do
    rule = { "tool" => "read_file", "verdict" => "ask", "origin" => "author" }
    released, revoked = 2.times.map do
      run = seed(tool("probe", "read_file"), ask("next"), approval_mode: "ask", approval_rules: [rule])
      start(run)
      assert_equal "needs_approval", run.tasks.find_by!(node_key: "probe").status
      run
    end
    released.update_column(:attention_reason, nil)
    assert_equal [released.id], candidates(released, revoked)
    Runs::ScheduleSweep.call
    assert_equal Runs::EvaluateQuiescence::APPROVAL_REASON, released.reload.attention_reason
    assert_equal [], candidates(released, revoked)

    approved = Runs::Tasks::Approve.call(Runs::Tasks::Approve::Command.new(
      run: released, task_key: "probe", acting_user: @human))
    assert_predicate approved, :accepted?
    clear_enqueued_jobs
    Runs::ScheduleSweep.call
    assert_nil released.reload.attention_reason
    assert_predicate Runs::Parks::Settle.call(node: approved.node, trusted: true,
      outcome: "completed", content: "accepted"), :applied?
    clear_enqueued_jobs
    Runs::ScheduleSweep.call
    assert_equal "dispatched", released.tasks.find_by!(node_key: "next").status

    @workspace.with_lock { @workspace.accept_archive }
    clear_enqueued_jobs
    Runs::ScheduleSweep.call
    assert_equal %w[canceled authority_lost], revoked.reload.values_at(:status, :failure_reason)
    assert_equal "canceled", revoked.tasks.find_by!(node_key: "probe").status
  end

  test "a detached receipt waits for the live mainline without repeatedly scheduling its Run" do
    run = seed(detached(ask("receipt")), ask("gate"), model("r2"))
    start(run)
    receipt = run.tasks.find_by!(node_key: "receipt")
    settled = Runs::Parks::Settle.call(node: receipt, claim_token: receipt.resolution_token,
      outcome: "completed", content: "receipt")
    assert_predicate settled, :applied?
    assert_predicate run, :mainline_live?
    assert_predicate run.tasks.unmailed_results, :exists?
    assert_equal [], candidates(run)
  end

  test "an absorbed ordinary tool timeout does not keep waking a busy Run for compaction" do
    run = seed(parallel(tool("late", "read_file", "on_failure" => "absorb"), ask("gate")), model("r2"))
    start(run)
    late = run.tasks.find_by!(node_key: "late")
    travel_to(late.deadline_at + 1.second) do
      assert_predicate Runs::Parks::Settle.call(node: late, timeout: true), :applied?
    end
    assert_equal "timed_out", late.reload.status
    assert_equal "dispatched", run.tasks.find_by!(node_key: "gate").status
    assert_equal [], candidates(run)
  end

  test "only a conversation can settle its deliverable with conversation-lifetime work still in flight" do
    standalone = waiting_loop
    standalone.deliverable.update_columns(status: "completed")
    task(standalone, "background", status: "dispatched", detached: true, lifetime: "conversation")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    hosted = create_run_backed_turn(conversation: conversation, acting_user: @human).run
    task(hosted, "branch", status: "dispatched", detached: true, lifetime: "conversation")
    answer = task(hosted, "answer", status: "completed")
    hosted.update!(deliverable_node: answer)
    assert_equal [hosted.id], candidates(standalone, hosted)
    turn_owned = task(hosted, "obligation", status: "dispatched", detached: true, lifetime: "turn")
    assert_equal [], candidates(standalone, hosted)
    turn_owned.update_columns(status: "completed", result_delivered_at: Time.current)
    Runs::ScheduleReady.call(run_id: hosted.id)
    assert_predicate hosted.reload, :delivered?
    assert_predicate hosted, :running?
  end

  test "a candidate window checks holders and the mainline without visiting their completed history" do
    run = waiting_loop
    attrs = run.attributes.slice("account_id", "workspace_id", "creating_user_id", "approval_mode", "status")
    peers = Run.insert_all!(Array.new(200) { attrs }, returning: [:id]).rows.flatten
    template = { account_id: run.account_id, type: Tasks::ToolTask.sti_name, authored_by: "kernel" }
    Task.insert_all!(Array.new(10_000) do |i|
      template.merge(run_id: run.id, node_key: "old_#{i}", type: Tasks::ModelTask.sti_name, status: "completed")
    end)
    Task.insert_all!(peers.map { |id| template.merge(run_id: id, node_key: "active", status: "dispatched") })
    run.deliverable.update_columns(status: "completed")
    task(run, "now", status: "dispatched")
    task(run, "unread", status: "completed", detached: true)
    connection = ApplicationRecord.lease_connection
    connection.execute("ANALYZE runs, tasks")
    scope = Runs::ScheduleReady.recovery_candidates(Run.where(id: [run.id, *peers.first(100)]))
    assert_equal [run.id], scope.pluck(:id)

    # Prepare the relation with the same Run IDs, statuses and other binds
    # Rails supplies. A literal EXPLAIN cannot exercise a generic plan.
    sql, binds = connection.send(:to_sql_and_binds, scope.select(:id).arel)
    values = connection.send(:type_casted_binds, binds).map { |value| connection.quote(value) }
    connection.execute("PREPARE run_candidate_window AS #{sql}")
    begin
      %w[force_custom_plan force_generic_plan].each do |mode|
        connection.execute("SET LOCAL plan_cache_mode = #{mode}")
        plan = ApplicationRecord.uncached do
          connection.select_values("EXPLAIN (ANALYZE, BUFFERS) EXECUTE run_candidate_window(#{values.join(", ")})").join("\n")
        end
        assert_no_match(/hashed SubPlan/i, plan, "the checks must stay on the selected Runs")
        probes = plan.split(/^  SubPlan \d+$/).drop(1)
        ["runs.variant_id IS NULL", "continuation_source"].each do |condition|
          probe = probes.find { |subplan| subplan.include?(condition) }
          assert_match(/Index(?: Only)? Scan using index_tasks_on_live_run_status/, probe)
          assert_match(/Index Cond: .*run_id = runs.id/, probe)
        end
      end
    ensure
      connection.execute("DEALLOCATE run_candidate_window")
    end
  end

  private

    def candidates(*runs)
      Runs::ScheduleReady.recovery_candidates(Run.where(id: runs.map(&:id))).order(:id).pluck(:id)
    end

    def waiting_loop
      run = seed(ask("wait"))
      start(run)
      run.reload
    end

    def start(run)
      Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
      Runs::ScheduleReady.call(run_id: run.id)
    end

    def task(run, key, **attributes)
      row = Task.insert_all!([{ account_id: run.account_id, run_id: run.id, node_key: key,
        type: Tasks::ToolTask.sti_name, tool_name: "read_file", authored_by: "kernel", **attributes }])
      Task.find(row.rows.sole.sole)
    end
end
