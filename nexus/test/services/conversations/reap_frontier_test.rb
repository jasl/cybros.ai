require "test_helper"

class Conversations::ReapFrontierTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @user = users(:member)
    @workspace = workspaces(:shared)
  end

  test "pinned ancestors consume the source window before a later collectible tombstone" do
    stamp = (Conversation::RETENTION_PERIOD + 1.day).ago
    kept = pinned_tombstones(2, stamp: stamp)
    collectible = conversation(tombstoned_at: stamp)

    first = Conversations::Reap.call(batch: 2).value

    assert_equal [2, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [stamp.iso8601(6), kept.last], first.cursor
    assert Conversation.exists?(collectible.id), "the source window cannot skip arbitrarily many pinned rows"

    last = Conversations::Reap.call(batch: 2,
      after_tombstoned_at: first.cursor.first, after_id: first.cursor.last).value
    assert_equal [1, 1, false], [last[:scanned], last[:reaped], last.more?]
    assert_equal [stamp.iso8601(6), collectible.id], last.cursor
    assert_not Conversation.exists?(collectible.id)
    assert_equal 2, Conversation.where(id: kept).count
  end

  test "a young ordinary tombstone costs budget but only a young side may reap" do
    stamp = 1.hour.ago
    ordinary = conversation(tombstoned_at: stamp)
    side = conversation(tombstoned_at: stamp, side: true)

    first = Conversations::Reap.call(batch: 1).value
    assert_equal [1, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [stamp.iso8601(6), ordinary.id], first.cursor
    assert Conversation.exists?(side.id)

    second = Conversations::Reap.call(batch: 1,
      after_tombstoned_at: first.cursor.first, after_id: first.cursor.last).value
    assert_equal [1, 1, true], [second[:scanned], second[:reaped], second.more?]
    assert_not Conversation.exists?(side.id)
    assert Conversation.exists?(ordinary.id), "ordinary tombstones retain their full retention window"

    last = Conversations::Reap.call(batch: 1,
      after_tombstoned_at: second.cursor.first, after_id: second.cursor.last).value
    assert_equal [0, 0, false], [last[:scanned], last[:reaped], last.more?]
  end

  test "a retained full page schedules exactly one continuation" do
    stamp = (Conversation::RETENTION_PERIOD + 1.day).ago.iso8601(6)
    result = Conversations::Outcome.accepted(Sweeps::Pass.new(
      counts: { scanned: 200, reaped: 0 }, cursor: [stamp, 123], more: true
    ))

    Conversations::Reap.stub(:call, result) do
      assert_enqueued_jobs 1, only: Conversations::ReapJob do
        assert_enqueued_with(job: Conversations::ReapJob, args: [stamp, 123]) do
          Conversations::ReapJob.perform_now
        end
      end
    end
  end

  test "the production source stops at its index window above fork pinned history" do
    now = Time.current
    Conversation.insert_all!(Array.new(8_000) { conversation_attributes(now) })
    stamp = (Conversation::RETENTION_PERIOD + 1.day).ago
    ids = pinned_tombstones(2_000, stamp: stamp)
    ApplicationRecord.lease_connection.execute("ANALYZE conversations, conversation_ancestries")

    first = nil
    sources = [capture_source { first = Conversations::Reap.call(batch: 200).value }]
    source_plan = explain(sources.first)
    assert_window(source_plan)
    assert_equal [200, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [stamp.iso8601(6), ids[199]], first.cursor

    sources << capture_source do
      second = Conversations::Reap.call(batch: 200,
        after_tombstoned_at: first.cursor.first, after_id: first.cursor.last).value
      assert_equal [200, 0, true], [second[:scanned], second[:reaped], second.more?]
      assert_equal [stamp.iso8601(6), ids[399]], second.cursor
    end
    assert_window(explain(sources.last))
  end

  private

    def conversation(**attributes)
      Conversation.create!(workspace: @workspace, creating_user: @user, **attributes)
    end

    def conversation_attributes(now)
      { account_id: @account.id, workspace_id: @workspace.id,
        creating_user_id: @user.id, answering_user_id: @user.id,
        last_activity_at: now, created_at: now, updated_at: now }
    end

    def pinned_tombstones(count, stamp:)
      now = Time.current
      common = conversation_attributes(now)
      ancestors = Conversation.insert_all!(Array.new(count) do
        common.merge(tombstoned_at: stamp)
      end, returning: %w[id]).rows.flatten
      children = Conversation.insert_all!(Array.new(count) { common }, returning: %w[id]).rows.flatten
      ConversationAncestry.insert_all!(ancestors.zip(children).map do |ancestor_id, child_id|
        { account_id: @account.id, conversation_id: child_id,
          ancestor_conversation_id: ancestor_id, depth: 1, boundary_position: -1,
          created_at: now, updated_at: now }
      end)
      ancestors
    end

    def capture_source
      sources = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:cached]
        next unless payload[:sql].start_with?('SELECT "conversations"."id", "conversations"."tombstoned_at"')

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

    def assert_window(plan)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using index_conversations_reap_frontier/, plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Filter:/, plan,
        "retention and dependency checks follow the tombstone source window")
      assert_match(/actual [^\n]*rows=200(?:\.0+)? loops=1/, plan)
    end
end
