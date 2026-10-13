require "test_helper"

class Workspaces::CollectTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:personal)
    3.times { |n| @workspace.store_entries.create!(namespace: "n", key: "k#{n}") }
  end

  # The three rules of the store's collect: workspace-anchored rows drain with the workspace,
  # conversation-anchored with their conversation, and a person's profile store outlives every
  # workspace.
  test "collects an eligible tombstone leaves-first and removes the row" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:curator))
    conversation_entry = conversation.store_entries.create!(namespace: "n", key: "c")
    user_entry = users(:owner).store_entries.create!(namespace: "n", key: "u")
    tombstone(@workspace, at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 10)

    assert_kind_of Sweeps::Pass, result
    # Three store rows, one conversation (its entry rides its cascade), the
    # workspace row.
    assert_equal 5, result[:processed]
    assert_not result.more?
    assert_nil Workspace.find_by(id: @workspace.id)
    assert_equal 0, StoreEntry.where(workspace_id: @workspace.id).count
    assert_not StoreEntry.exists?(conversation_entry.id), "a conversation's rows leave with it"
    assert StoreEntry.exists?(user_entry.id), "the person's store outlives the workspace"
  end

  test "a user-anchored row alone never gates the workspace collect" do
    @workspace.store_entries.delete_all
    users(:curator).store_entries.create!(namespace: "n", key: "u")
    tombstone(@workspace, at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 10)

    assert_equal 1, result[:processed]
    assert_nil Workspace.find_by(id: @workspace.id)
    assert_equal 1, StoreEntry.for_user(users(:curator).id).count
  end

  # The stage the conversation plane earned and the loop plane was missing:
  # without it a workspace that ever hosted a loop is uncollectible behind
  # the graph's own FKs, and the collector dies on every pass.
  test "a workspace that hosted an agent loop collects, loop aggregate and all" do
    workspace = workspaces(:shared)
    created = create_loop(model("a"), model("b", "prompt" => "q"),
      workspace: workspace, creating_user: users(:member))
    assert_predicate created, :created?
    agent_run = created.agent_run
    actor = Speakers::Resolve.member(account: workspace.account, user: users(:member))
    ConversationInput.create!(
      account: workspace.account, host: agent_run, queue_position: 0, kind: "message",
      speaker: actor, authoring_user: users(:member)
    )
    tombstone(workspace, at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 50)

    assert_kind_of Sweeps::Pass, result
    assert_nil Workspace.find_by(id: workspace.id)
    assert_nil AgentRun.find_by(id: agent_run.id)
    assert_equal 0, AgentRunTask.where(agent_run_id: agent_run.id).count
    assert_equal 0, ConversationEventItem.where(host: agent_run).count
    assert_no_hosted_orphans
  end

  test "a loop with live step work fences its workspace instead of wedging the pass" do
    workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(workspace.account)
    created = create_loop(model("a"), workspace: workspace, creating_user: users(:member))
    agent_run = created.agent_run
    ModelInvocation.create!(
      agent_run: agent_run, creating_user: users(:member),
      internal_creation_key: "agent_run_task:#{agent_run.agent_run_tasks.sole.id}:0",
      provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )
    tombstone(workspace, at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 50)

    assert_kind_of Sweeps::Pass, result, "the pass completes rather than raising"
    assert Workspace.exists?(workspace.id), "live step work holds the container"
    assert AgentRun.exists?(agent_run.id)
  end

  test "only deleted tombstones past the thirty-day clock are eligible" do
    tombstone(@workspace, at: 10.days.ago)
    workspaces(:shared).update_columns(state: "deleting", deleted_at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 10)

    assert_equal 0, result[:processed]
    assert Workspace.exists?(@workspace.id)
    assert Workspace.exists?(workspaces(:shared).id)
  end

  test "the caller's row budget bounds a call and a restart finishes the graph" do
    tombstone(@workspace, at: 31.days.ago)

    first = Workspaces::Collect.call(budget: 2)
    assert_equal 2, first[:processed]
    assert first.more?
    assert Workspace.exists?(@workspace.id), "leaves drain before the row"

    second = Workspaces::Collect.call(budget: 10)
    assert_equal 2, second[:processed]
    assert_not second.more?
    assert_nil Workspace.find_by(id: @workspace.id)
  end

  test "receipts share the row budget and block parent collection until drained" do
    3.times { |index| create_receipt(@workspace, key: "receipt-#{index}") }
    tombstone(@workspace, at: 31.days.ago)

    first = Workspaces::Collect.call(budget: 4)

    assert_equal 4, first[:processed]
    assert first.more?
    assert Workspace.exists?(@workspace.id)
    assert_equal 0, StoreEntry.where(workspace_id: @workspace.id).count
    assert_equal 2, WorkspaceCommandReceipt.where(workspace_id: @workspace.id).count

    second = Workspaces::Collect.call(budget: 3)

    assert_equal 3, second[:processed]
    assert second.more?,
      "a fully consumed work budget schedules one conservative continuation"
    assert_nil Workspace.find_by(id: @workspace.id)
    assert_equal 0, WorkspaceCommandReceipt.where(workspace_id: @workspace.id).count

    third = Workspaces::Collect.call(budget: 3)
    assert_equal 0, third[:processed]
    assert_not third.more?
  end

  test "conversation receipts with collected hosts drain before their workspace" do
    collectible = create_tombstone(name: "Collected receipt hosts", at: 31.days.ago)
    insert_conversation_receipts(workspace: collectible, count: 3)
    receipts = ConversationCommandReceipt.where(workspace: collectible)
    assert_equal 3, receipts.count, "weak host references survive host collection"
    assert_not Conversation.exists?(workspace: collectible)

    3.downto(1) do |remaining|
      result = Workspaces::Collect.call(budget: 1)

      assert_equal 1, result[:processed]
      assert result.more?
      assert_equal remaining - 1, receipts.count, "one receipt consumes one unit of work"
      assert Workspace.exists?(collectible.id), "parent deletion must not cascade uncharged receipts"
    end

    result = Workspaces::Collect.call(budget: 1)

    assert_equal 1, result[:processed]
    assert_not Workspace.exists?(collectible.id)
  end

  test "both receipt families share one workspace collection budget" do
    collectible = create_tombstone(name: "Mixed receipt history", at: 31.days.ago)
    2.times do |index|
      create_receipt(collectible, key: "mixed-#{index}").update_columns(created_at: 32.days.ago)
    end
    insert_conversation_receipts(workspace: collectible, count: 3)
    remaining_receipts = -> {
      WorkspaceCommandReceipt.where(workspace: collectible).count +
        ConversationCommandReceipt.where(workspace: collectible).count
    }

    first = Workspaces::Collect.call(budget: 3)

    assert_equal 3, first[:processed]
    assert first.more?
    assert_equal 2, remaining_receipts.call
    assert Workspace.exists?(collectible.id)

    second = Workspaces::Collect.call(budget: 2)

    assert_equal 2, second[:processed]
    assert second.more?
    assert_equal 0, remaining_receipts.call
    assert Workspace.exists?(collectible.id)

    last = Workspaces::Collect.call(budget: 1)
    assert_equal 1, last[:processed]
    assert_not Workspace.exists?(collectible.id)
  end

  test "the budget spans workspaces and leaves the tail restartable" do
    tombstone(@workspace, at: 31.days.ago)
    other = workspaces(:dedicated)
    tombstone(other, at: 32.days.ago)

    # 3 entries + 2 rows = 5 total; a budget of 4 drains every leaf and one
    # Workspace row.
    result = Workspaces::Collect.call(budget: 4)

    assert_equal 4, result[:processed]
    assert result.more?
    remaining = [@workspace, other].count { |workspace| Workspace.exists?(workspace.id) }
    assert_equal 1, remaining

    rest = Workspaces::Collect.call(budget: 4)
    assert_equal 1, rest[:processed]
    assert_not rest.more?
    assert_equal 0, Workspace.where(id: [@workspace.id, other.id]).count
  end

  test "collects the oldest eligible tombstone first" do
    newer = create_tombstone(name: "Newer tombstone", at: 31.days.ago)
    older = create_tombstone(name: "Older tombstone", at: 32.days.ago)

    result = Workspaces::Collect.call(budget: 1)

    assert_equal 1, result[:processed]
    assert result.more?
    assert Workspace.exists?(newer.id)
    assert_not Workspace.exists?(older.id)
  end

  test "database round trips stay constant as a batch grows" do
    create_tombstone(name: "Single tombstone", at: 31.days.ago)
    single_queries = collect_query_count { Workspaces::Collect.call(budget: 10) }

    tombstones = 4.times.map do |index|
      create_tombstone(name: "Batch tombstone #{index}", at: 31.days.ago)
    end
    batch_queries = collect_query_count { Workspaces::Collect.call(budget: 10) }

    assert_equal 0, Workspace.where(id: tombstones.map(&:id)).count
    assert_equal single_queries, batch_queries,
      "collecting more rows in one bounded batch must not add database round trips"
  end

  test "a reaper with guarded delete losers freshly reports the remaining eligible backlog" do
    candidates = 4.times.map do |index|
      accounts(:cybros).workspaces.create!(
        creator: users(:owner), owner: users(:owner), name: "Candidate #{index}"
      )
    end
    candidates.each { |workspace| tombstone(workspace, at: 31.days.ago) }

    # A full candidate window must remain continuable even when every guarded
    # delete loses. Its cursor advances so the same losers cannot hide the
    # rest of the ordered scan.
    first = Workspaces::Collect.call(budget: 2)
    assert first.more?

    losing_reaper = Workspaces::Collect.new(budget: 2)
    second = losing_reaper.stub(:drain_store_entries, 0) do
      losing_reaper.stub(:drain_receipts, 0) do
        losing_reaper.stub(:drain_workspaces, 0) { losing_reaper.call }
      end
    end

    assert_kind_of Sweeps::Pass, second
    assert_equal 0, second[:processed]
    assert Workspace.where(id: candidates.map(&:id)).exists?,
      "eligible rows beyond the lost candidate window must still form a backlog"
    assert second.more?
    assert_not_nil second.cursor.first
    assert_operator second.cursor.last, :positive?
  end

  test "a full blocked window advances past its tombstone without starving the tail" do
    blocked = create_tombstone(name: "Blocked tombstone", at: 32.days.ago)
    inference_request = InferenceRequest.create!(
      account: blocked.account, workspace: blocked, creating_user: users(:owner),
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(inference_request: inference_request)
    collectible = create_tombstone(name: "Collectible tail", at: 31.days.ago)

    first = Workspaces::Collect.call(budget: 1)

    assert_equal 0, first[:processed]
    assert first.more?
    assert_equal blocked.id, first.cursor.last

    second = Workspaces::Collect.call(
      budget: 1,
      after_deleted_at: first.cursor.first,
      after_id: first.cursor.last
    )

    assert_equal 1, second[:processed]
    assert Workspace.exists?(blocked.id)
    assert_not Workspace.exists?(collectible.id)
  end

  test "the receipt source scan uses the workspace child index at scale" do
    live = accounts(:cybros).workspaces.create!(
      creator: users(:owner), owner: users(:owner), name: "Live receipt history"
    )
    collectible = create_tombstone(name: "Collectible receipt history", at: 31.days.ago)
    insert_receipts(workspace: live, count: 8_000)
    insert_receipts(workspace: collectible, count: 400)
    ApplicationRecord.lease_connection.execute(
      "ANALYZE workspaces, workspace_command_receipts"
    )

    source_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "workspace_command_receipts"."id"') &&
          sql.include?('"workspace_command_receipts"."workspace_id"')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      result = Workspaces::Collect.call(budget: 100)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 100, result[:processed]
    assert source_scan, "the public collector must execute its bounded receipt source scan"
    plan = explain(*source_scan)
    assert_match(/Limit/, plan)
    assert_match(
      /Index(?: Only)? Scan using index_workspace_command_receipts_on_workspace_id_and_id/,
      plan
    )
    assert_no_match(/Seq Scan on workspace_command_receipts(?:\s|$)/, plan)
  end

  test "the conversation receipt source scan is index bounded at scale" do
    live = accounts(:cybros).workspaces.create!(
      creator: users(:owner), owner: users(:owner), name: "Live conversation receipt history"
    )
    collectible = create_tombstone(name: "Collectible conversation receipt history", at: 31.days.ago)
    insert_conversation_receipts(workspace: live, count: 8_000)
    insert_conversation_receipts(workspace: collectible, count: 400)
    ApplicationRecord.lease_connection.execute("ANALYZE workspaces, conversation_command_receipts")

    source_scan = nil
    deletes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "conversation_command_receipts"."id"') &&
          sql.include?('"conversation_command_receipts"."workspace_id"')
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('DELETE FROM "conversation_command_receipts"')
        deletes << sql
      end
    end
    begin
      result = Workspaces::Collect.call(budget: 100)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert source_scan, "the collector must charge conversation receipts before parent deletion"
    assert_equal 100, result[:processed]
    assert_equal 300, ConversationCommandReceipt.where(workspace: collectible).count
    assert_equal 8_000, ConversationCommandReceipt.where(workspace: live).count
    assert_equal 1, deletes.length
    assert_no_match(/SELECT/i, deletes.sole, "applying the window deletes only materialized ids")

    sql, binds = source_scan
    plan = ApplicationRecord.lease_connection
      .select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    assert_match(/Limit .*actual .*rows=100(?:\.0+)? loops=1/, plan)
    assert_match(
      /Index(?: Only)? Scan using index_conversation_command_receipts_on_workspace_id_and_id .*actual .*rows=100(?:\.0+)? loops=1/,
      plan
    )
    assert_match(/Index Cond: \(workspace_id = /, plan)
    assert_no_match(/Sort|Bitmap|Seq Scan|Filter:/, plan)
    assert_match(/Buffers: shared/, plan)
  end

  # Every drain application materializes its bounded ids before its DELETE —
  # the receipt stages carry this pin already; these are the other two. A
  # LIMIT left behind as a subquery invites the outer DELETE to hash the id
  # set and scan the whole table instead of probing the primary key.
  test "store-entry and workspace deletion materialize their bounded ids" do
    tombstone(@workspace, at: 31.days.ago)

    deletes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      deletes << sql if sql.start_with?("DELETE FROM")
    end
    begin
      assert_not Workspaces::Collect.call(budget: 10).more
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    store_delete = deletes.find { |sql| sql.include?('"store_entries"') }
    workspace_delete = deletes.find { |sql| sql.start_with?('DELETE FROM "workspaces"') }
    assert store_delete, "the pass must drain the fixture workspace's store entries"
    assert workspace_delete, "the pass must delete the eligible workspace row"
    [store_delete, workspace_delete].each do |sql|
      assert_no_match(/SELECT/i, sql,
        "a drain DELETE carries a literal id set, never a nested scan")
    end
  end

  private

    # The polymorphic host carries no FK: the cascades are the only thing between a collected host
    # and an orphan the DB cannot refuse.
    def assert_no_hosted_orphans
      [ConversationInput, ConversationEventItem].each do |model|
        { "Conversation" => Conversation, "AgentRun" => AgentRun }.each do |type, host_model|
          orphans = model.where(host_type: type).where.not(host_id: host_model.select(:id))
          assert_equal 0, orphans.count, "#{model.name} rows outlived their #{type} host"
        end
      end
    end

    def create_tombstone(name:, at:)
      workspace = accounts(:cybros).workspaces.create!(
        creator: users(:owner), owner: users(:owner), name: name
      )
      tombstone(workspace, at: at)
      workspace
    end

    def tombstone(workspace, at:)
      workspace.update_columns(state: "deleted", deleted_at: at)
    end

    def create_receipt(workspace, key:)
      WorkspaceCommandReceipt.create!(
        account: workspace.account,
        workspace: workspace,
        acting_user: users(:owner),
        operation: :store_entry_create,
        idempotency_key: key,
        request_digest: "a" * 64,
        response_status: 201,
        response_body: {},
      )
    end

    def insert_receipts(workspace:, count:)
      now = Time.current
      WorkspaceCommandReceipt.insert_all!(
        count.times.map do |index|
          {
            account_id: workspace.account_id,
            workspace_id: workspace.id,
            acting_user_id: users(:owner).id,
            operation: "store_entry_create",
            idempotency_key: "collect-plan-#{workspace.id}-#{index}",
            request_digest: "a" * 64,
            response_status: 201,
            created_at: now,
            updated_at: now,
          }
        end
      )
    end

    # A stopped receipt reaper may leave this history after its host is gone;
    # workspace collection must remain bounded when that independent job resumes later.
    def insert_conversation_receipts(workspace:, count:)
      host = Conversation.create!(workspace: workspace, creating_user: users(:owner))
      accepted_at = 32.days.ago
      ConversationCommandReceipt.insert_all!(
        count.times.map do |index|
          {
            account_id: workspace.account_id,
            workspace_id: workspace.id,
            host_type: "Conversation",
            host_id: host.id,
            acting_user_id: users(:owner).id,
            operation: "input_create",
            idempotency_key: "collect-input-#{workspace.id}-#{index}",
            request_digest: "a" * 64,
            response_status: 202,
            created_at: accepted_at,
            updated_at: accepted_at,
          }
        end
      )
      host.destroy!
    end

    def collect_query_count
      count = 0
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached] || payload[:name] == "SCHEMA"

        count += 1
      end

      connection = ActiveRecord::Base.lease_connection
      connection.clear_query_cache
      connection.materialize_transactions
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      count
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
