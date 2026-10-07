require "test_helper"

# The three recurring shells (2026-07-30 plan): shallow, level-triggered,
# and exactly one continuation when a bounded pass reports more.
class WorkspaceMaintenanceJobsTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  test "the sweep job converges transitions and enqueues no idle continuation" do
    workspace = workspaces(:personal)
    workspace.update_columns(state: "restoring")

    assert_no_enqueued_jobs(only: Workspaces::SweepTransitionsJob) do
      Workspaces::SweepTransitionsJob.perform_now
    end

    assert_equal "active", workspace.reload.state
  end

  test "an overflowing sweep enqueues exactly one cursor continuation" do
    [workspaces(:personal), workspaces(:shared)].each do |workspace|
      workspace.update_columns(state: "archiving", archived_at: Time.current)
    end

    cursor = [workspaces(:personal).id, workspaces(:shared).id].min
    stub_const(Workspaces::SweepTransitionsJob, :BUDGET, 1) do
      assert_enqueued_with(job: Workspaces::SweepTransitionsJob, args: [cursor]) do
        Workspaces::SweepTransitionsJob.perform_now
      end
    end
  end

  test "the collect job drains an eligible tombstone" do
    workspace = workspaces(:personal)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    assert_no_enqueued_jobs(only: Workspaces::CollectJob) do
      Workspaces::CollectJob.perform_now
    end

    assert_nil Workspace.find_by(id: workspace.id)
  end

  test "an overflowing collection enqueues exactly one continuation" do
    insert_eligible_tombstones(Workspaces::CollectJob::BUDGET + 1)

    assert_enqueued_jobs 1, only: Workspaces::CollectJob do
      assert_enqueued_with(job: Workspaces::CollectJob, args: [nil, 0]) do
        Workspaces::CollectJob.perform_now
      end
    end

    # One eligible tombstone survives the budget for the continuation to drain.
    assert_equal 1, Workspace.where(state: "deleted").count
  end

  # A partial terminal window has no tail to scan. It stays silent and the
  # daily level trigger revisits the blocker after its obligation settles.
  test "a partial window held by an obligation does not self-enqueue" do
    account = accounts(:cybros)
    workspace = account.workspaces.create!(
      creator: users(:owner), owner: users(:owner), name: "Held backlog"
    )
    inference_request = InferenceRequest.create!(
      account: account, workspace: workspace, creating_user: users(:owner),
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(inference_request: inference_request)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    assert_no_enqueued_jobs(only: Workspaces::CollectJob) do
      Workspaces::CollectJob.perform_now
    end

    assert Workspace.exists?(workspace.id), "the obligation still holds the Workspace"
  end

  test "a full blocked window enqueues one cursor continuation" do
    account = accounts(:cybros)
    workspace = account.workspaces.create!(
      creator: users(:owner), owner: users(:owner), name: "Held scan window"
    )
    inference_request = InferenceRequest.create!(
      account: account, workspace: workspace, creating_user: users(:owner),
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(inference_request: inference_request)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)
    cursor_time = workspace.deleted_at.iso8601(6)

    stub_const(Workspaces::CollectJob, :BUDGET, 1) do
      assert_enqueued_with(
        job: Workspaces::CollectJob, args: [cursor_time, workspace.id]
      ) do
        Workspaces::CollectJob.perform_now
      end
    end
  end

  test "receipt leaves consume the collection budget and enqueue one continuation" do
    workspace = accounts(:cybros).workspaces.create!(
      creator: users(:owner), owner: users(:owner), name: "Receipt backlog"
    )
    insert_receipts(workspace: workspace, count: 3)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    stub_const(Workspaces::CollectJob, :BUDGET, 2) do
      assert_enqueued_jobs 1, only: Workspaces::CollectJob do
        assert_enqueued_with(job: Workspaces::CollectJob, args: [nil, 0]) do
          Workspaces::CollectJob.perform_now
        end
      end
    end

    assert Workspace.exists?(workspace.id)
    assert_equal 1, WorkspaceCommandReceipt.where(workspace_id: workspace.id).count
  end

  test "the receipt reap removes only expired rows within its batch" do
    fresh = WorkspaceCommandReceipt.create!(
      account: accounts(:cybros), workspace: workspaces(:shared), acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "fresh",
      request_digest: "a" * 64, response_status: 201, response_body: {},
    )
    expired = WorkspaceCommandReceipt.create!(
      account: accounts(:cybros), workspace: workspaces(:shared), acting_user: users(:member),
      operation: :workspace_create, idempotency_key: "old",
      request_digest: "a" * 64, response_status: 201, response_body: {},
    )
    expired.update_columns(created_at: 25.hours.ago)

    # A drained pass stays silent: nothing left means no continuation wake.
    assert_no_enqueued_jobs(only: WorkspaceCommandReceipts::ReapJob) do
      WorkspaceCommandReceipts::ReapJob.perform_now
    end

    assert WorkspaceCommandReceipt.exists?(fresh.id)
    assert_nil WorkspaceCommandReceipt.find_by(id: expired.id)
  end

  test "a full reap batch enqueues exactly one continuation" do
    insert_expired_receipts(WorkspaceCommandReceipts::ReapJob::BATCH)

    assert_enqueued_jobs 1, only: WorkspaceCommandReceipts::ReapJob do
      assert_enqueued_with(job: WorkspaceCommandReceipts::ReapJob, args: []) do
        WorkspaceCommandReceipts::ReapJob.perform_now
      end
    end

    assert_equal 0, WorkspaceCommandReceipt.count
  end

  test "the reap batch bound deletes only the oldest expired rows" do
    first_expired, second_expired = insert_expired_receipts(2).map do |id|
      WorkspaceCommandReceipt.find(id)
    end
    WorkspaceCommandReceipt.where(id: first_expired.id).update_all(created_at: 25.hours.ago)
    WorkspaceCommandReceipt.where(id: second_expired.id).update_all(created_at: 26.hours.ago)

    assert_equal 1, WorkspaceCommandReceipt.reap(batch: 1)

    assert WorkspaceCommandReceipt.exists?(first_expired.id)
    assert_nil WorkspaceCommandReceipt.find_by(id: second_expired.id),
      "the index-ordered source window starts with the oldest acceptance"
  end

  test "the receipt expiry scan has a matching continuation index" do
    index = WorkspaceCommandReceipt.connection
      .indexes(:workspace_command_receipts)
      .find { |candidate| candidate.name == "index_workspace_command_receipts_on_created_at_and_id" }

    assert index
    assert_equal %w[created_at id], index.columns
  end

  test "receipt expiry bounds both discovery and deletion at scale" do
    insert_fresh_receipts(8_000)
    insert_expired_receipts(400)
    ApplicationRecord.lease_connection.execute("ANALYZE workspace_command_receipts")

    source_scan = nil
    deletion = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?('SELECT "workspace_command_receipts"."id"')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('DELETE FROM "workspace_command_receipts"')
        deletion ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      assert_equal 100, WorkspaceCommandReceipt.reap(batch: 100)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert source_scan
    assert deletion
    source_plan = explain(*source_scan)
    deletion_plan = explain(*deletion)
    assert_match(
      /Index(?: Only)? Scan using index_workspace_command_receipts_on_created_at_and_id/,
      source_plan
    )
    assert_match(/workspace_command_receipts_pkey/, deletion_plan)
    assert_no_match(/Seq Scan on workspace_command_receipts(?:\s|$)/, deletion_plan)
    assert_no_match(/Hash Semi Join/, deletion_plan)
  end

  test "the recurring schedule wires all three maintenance shells" do
    production = recurring_schedule

    assert_equal Workspaces::SweepTransitionsJob.name,
      production.dig("sweep_workspace_transitions", "class")
    assert_equal "every minute", production.dig("sweep_workspace_transitions", "schedule")
    assert_equal Workspaces::CollectJob.name, production.dig("collect_workspaces", "class")
    assert_equal "every day at 4:20am", production.dig("collect_workspaces", "schedule")
    assert_equal WorkspaceCommandReceipts::ReapJob.name,
      production.dig("reap_workspace_command_receipts", "class")
    assert_equal "every hour at minute 35",
      production.dig("reap_workspace_command_receipts", "schedule")
  end

  private

    # Overflow is constructed honestly — BUDGET+1 real eligible rows in one
    # statement — so the continuation fires from the shipped constant, not a
    # stubbed one.
    def insert_eligible_tombstones(count)
      now = Time.current
      Workspace.insert_all!(
        count.times.map do |n|
          {
            account_id: accounts(:cybros).id,
            creator_id: users(:curator).id,
            owner_id: users(:curator).id,
            name: "Tombstone #{n}",
            state: "deleted",
            deleted_at: 31.days.ago,
            created_at: now,
            updated_at: now,
          }
        end
      )
    end

    def insert_expired_receipts(count)
      now = Time.current
      WorkspaceCommandReceipt.insert_all!(
        count.times.map do |n|
          {
            account_id: accounts(:cybros).id,
            workspace_id: workspaces(:shared).id,
            acting_user_id: users(:member).id,
            operation: "store_entry_create",
            idempotency_key: "expired-#{n}",
            request_digest: "a" * 64,
            response_status: 201,
            created_at: now - 25.hours,
            updated_at: now,
          }
        end
      ).rows.map(&:first)
    end

    def insert_fresh_receipts(count)
      now = Time.current
      WorkspaceCommandReceipt.insert_all!(
        count.times.map do |n|
          {
            account_id: accounts(:cybros).id,
            workspace_id: workspaces(:shared).id,
            acting_user_id: users(:member).id,
            operation: "store_entry_create",
            idempotency_key: "fresh-plan-#{n}",
            request_digest: "a" * 64,
            response_status: 201,
            created_at: now,
            updated_at: now,
          }
        end
      )
    end

    def insert_receipts(workspace:, count:)
      now = Time.current
      WorkspaceCommandReceipt.insert_all!(
        count.times.map do |n|
          {
            account_id: workspace.account_id,
            workspace_id: workspace.id,
            acting_user_id: users(:owner).id,
            operation: "store_entry_create",
            idempotency_key: "workspace-#{workspace.id}-#{n}",
            request_digest: "a" * 64,
            response_status: 201,
            created_at: now,
            updated_at: now,
          }
        end
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
