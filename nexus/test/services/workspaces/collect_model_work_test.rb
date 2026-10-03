require "test_helper"

# Destructive collection of a Workspace's model work. Body deletion cascades its entries and upload
# joins. That releases uploads while leaving fragments to their own age-gated reaper.
class Workspaces::CollectModelWorkTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def collectible_workspace(uploads: 0)
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Collect #{SecureRandom.hex(3)}"
    )
    bound = Array.new(uploads) { upload }
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    OneShotCreateReceipt.create!(
      one_shot: one_shot, idempotency_key: SecureRandom.uuid,
      request_digest: SecureRandom.hex(32)
    )
    ContentBodies::Replace.call(
      owner: one_shot, role: "input", entries: [{ "text" => "collect me" }],
      uploads: bound, seal: true
    )
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: invocation.id), reason: "workspace_deleted"
    )
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)
    [workspace, one_shot, bound]
  end

  def upload
    bytes = "collect-#{SecureRandom.hex(4)}"
    @account.content_uploads.create!(
      creating_user: @owner,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes), filename: "c.png", content_type: "image/png"
      )
    )
  end

  def collect(budget: 500)
    Workspaces::Collect.call(budget: budget)
  end

  test "collection drains the whole aggregate leaves-first" do
    workspace, one_shot, = collectible_workspace(uploads: 1)
    body = one_shot.content_bodies.sole

    5.times { break unless collect.more? }

    assert_nil Workspace.find_by(id: workspace.id)
    assert_nil OneShot.find_by(id: one_shot.id)
    assert_not ContentBody.exists?(id: body.id)
    assert_equal 0, ContentBodyEntry.where(content_body_id: body.id).count
    assert_equal 0, ContentBodyUpload.where(content_body_id: body.id).count
    assert_equal 0, ModelInvocation.where(workspace_id: workspace.id).count
    assert_equal 0, OneShotCreateReceipt.where(one_shot_id: one_shot.id).count
  end

  # Collection releases the liveness join without deleting the upload or
  # purging its blob.
  test "collection releases uploads without deleting them" do
    _workspace, _one_shot, bound = collectible_workspace(uploads: 2)

    5.times { break unless collect.more? }

    bound.each do |record|
      assert ContentUpload.exists?(id: record.id), "the upload outlives the Workspace that used it"
      record.reload
      assert_empty record.content_body_uploads
      assert record.file.attached?, "the blob is not purged here"
    end
  end

  test "one aggregate cascades an upload shared by many bodies without updating it" do
    shared = upload
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Shared #{SecureRandom.hex(3)}"
    )
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    # Three bodies across BOTH owner branches share the one upload (the
    # one_shot branch now admits only `input` — re-audit trim — so the
    # other two ride the invocation, exactly where their design settled).
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    ContentBodies::Replace.call(
      owner: one_shot, role: "input", entries: [{ "text" => "shared input" }],
      uploads: [shared], seal: true
    )
    %w[response reasoning].each do |role|
      ContentBodies::Replace.call(
        owner: invocation, role: role, entries: [{ "text" => "shared #{role}" }],
        uploads: [shared], seal: true
      )
    end
    ModelInvocation.where(id: invocation.id).update_all(status: "completed")
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)
    assert_equal 3, shared.content_body_uploads.count

    updates = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      updates << sql if sql.start_with?("UPDATE \"content_uploads\"") && !payload[:cached]
    end
    begin
      5.times { break unless collect.more? }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert ContentUpload.exists?(id: shared.id)
    assert_empty shared.reload.content_body_uploads
    assert_empty updates, "join cascades must not write the upload row"
  end

  # Fragments are strand-then-reap, not cascade: the entry delete releases
  # them, and the age-gated reaper collects them separately.
  test "collection strands fragments rather than deleting them" do
    _workspace, one_shot, = collectible_workspace
    fragment_id = one_shot.content_bodies.sole.content_body_entries.sole.content_fragment_id

    5.times { break unless collect.more? }

    assert ContentFragment.exists?(id: fragment_id),
      "an orphaned fragment is the reaper's to collect, on its own age gate"
  end

  # The gate is absence of obligations, not terminal status. Live work keeps
  # the Workspace out of the collectible set entirely.
  test "a Workspace with live work is not collectible" do
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Live #{SecureRandom.hex(3)}"
    )
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(one_shot: one_shot)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    5.times { break unless collect.more? }

    assert Workspace.exists?(id: workspace.id),
      "terminal status alone is not the gate; an unfinished obligation holds the Workspace"
  end

  test "a pending-settlement attempt on terminal work holds the Workspace" do
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Pending #{SecureRandom.hex(3)}"
    )
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    ModelInvocationAttempt.create!(
      account: @account, model_invocation: invocation, ordinal: 1,
      admission_shape: "priced", deadline_at: 10.minutes.from_now,
      settlement_state: "pending"
    )
    ModelInvocation.where(id: invocation.id).update_all(status: "completed")
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    5.times { break unless collect.more? }
    assert Workspace.exists?(id: workspace.id),
      "a pending attempt still owns a future receipt; the teardown waits"

    ModelInvocationAttempt.where(model_invocation_id: invocation.id)
      .update_all(settlement_state: "settled")
    5.times { break unless collect.more? }
    assert_not Workspace.exists?(id: workspace.id), "settled, the fence lifts"
  end

  test "a model-work obligation does not block independent collection leaves" do
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Blocked leaves #{SecureRandom.hex(3)}"
    )
    entry = workspace.store_entries.create!(
      namespace: "collection", key: SecureRandom.hex(4), value: { "kept" => false }
    )
    receipt = WorkspaceCommandReceipt.create!(
      account: @account, workspace: workspace, acting_user: @owner,
      operation: :store_entry_create, idempotency_key: SecureRandom.uuid,
      request_digest: "a" * 64, response_status: 201, response_body: {}
    )
    WorkspaceCommandReceipt.where(id: receipt.id).update_all(created_at: 25.hours.ago)
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    ContentBodies::Replace.call(
      owner: one_shot, role: "input", entries: [{ "text" => "still required" }]
    )
    body = one_shot.content_bodies.sole
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    result = collect(budget: 10)

    assert_equal 2, result[:processed]
    assert_not StoreEntry.exists?(id: entry.id)
    assert_not WorkspaceCommandReceipt.exists?(id: receipt.id)
    assert Workspace.exists?(id: workspace.id),
      "the Workspace remains while model work still owns an obligation"
    assert OneShot.exists?(id: one_shot.id)
    assert ModelInvocation.exists?(id: invocation.id)
    assert ContentBody.exists?(id: body.id)
    assert ContentBodyEntry.exists?(content_body_id: body.id)
  end

  test "collection is bounded and restartable" do
    3.times { collectible_workspace }

    first = collect(budget: 2)

    assert_operator first[:processed], :<=, 2
    assert first.more?
    10.times { break unless collect(budget: 2).more }
    assert_equal 0, Workspace.where(state: "deleted").where(deleted_at: ..31.days.ago).count
  end

  # The aggregate budget must bound the source scan as well as the returned
  # ids. OneShot history from unrelated live Workspaces is deliberately much
  # larger and older than the collectible set so a global primary-key walk
  # cannot accidentally look bounded.
  test "the model-work source scan uses the workspace-id index at scale" do
    live_workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Live history"
    )
    collectible_workspaces = 4.times.map do |index|
      @account.workspaces.create!(
        creator: @owner, owner: @owner, name: "Collectible history #{index}"
      ).tap do |workspace|
        workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)
      end
    end
    seed_model_work_history(Array.new(8_000, live_workspace.id))
    seed_model_work_history(
      Array.new(400) { |index| collectible_workspaces[index % collectible_workspaces.length].id }
    )
    ApplicationRecord.lease_connection.execute(
      "ANALYZE workspaces, one_shots, model_invocations"
    )

    source_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "one_shots"."id"') &&
          sql.include?('"one_shots"."workspace_id"')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = collect(budget: 100)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 100, result[:processed]
    assert source_scan, "the public collector must execute its bounded OneShot source scan"
    sql, binds = source_scan
    plan = ApplicationRecord.lease_connection
      .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")

    assert_match(/Limit/, plan)
    assert_match(
      /Index(?: Only)? Scan using index_one_shots_on_workspace_id_and_id/,
      plan
    )
    assert_no_match(/Seq Scan on one_shots(?:\s|$)/, plan)
    # The naive relation-subquery shape also passes the three assertions
    # above: it plans as a Merge Semi Join that walks this same index
    # GLOBALLY from the lowest workspace_id — every live-history row — with
    # no entry condition, and emits the budget only at the top. Only the
    # materialized parent-id set produces a bounded entry condition, so that
    # condition is the pin.
    assert_match(/Index Cond: .*workspace_id = ANY/, plan,
      "the source scan must enter the child index through the materialized parent ids")
    assert_no_match(/Semi Join/, plan,
      "a semi-join over the child index is the global walk this fence exists to reject")
  end

  private

    def seed_model_work_history(workspace_ids)
      selection = DevModelLane.selection(
        workload: "text_generation", account: @account
      )
      invocation_attributes = DevModelLane.invocation_attributes(selection)
      now = Time.current
      one_shot_ids = OneShot.insert_all!(
        workspace_ids.map do |workspace_id|
          {
            account_id: @account.id, workspace_id: workspace_id,
            creating_user_id: @owner.id, workload: "text_generation",
            created_at: now, updated_at: now,
          }
        end,
        returning: %w[id]
      ).rows.flatten

      ModelInvocation.insert_all!(
        one_shot_ids.zip(workspace_ids).map do |one_shot_id, workspace_id|
          {
            account_id: @account.id, workspace_id: workspace_id,
            creating_user_id: @owner.id, one_shot_id: one_shot_id,
            workload: "text_generation", purpose: "one_shot_attempt",
            **invocation_attributes,
            priority: 0, internal_creation_key: "collect-plan-#{one_shot_id}",
            status: "completed", terminal_at: now,
            created_at: now, updated_at: now,
          }
        end
      )
    end
end
