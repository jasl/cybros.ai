require "test_helper"

# Explicit measurement; ordinary suites do not load this file. All seeded
# history and each EXPLAIN DELETE are rolled back by the test transactions.
# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/conversation_event_reaping.rb
class ConversationEventReapingBenchmark < ActiveJob::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "the real event reaper stops its source at one batch and deletes only those ids" do
    sources = narration_sources
    now = DatabaseClock.now
    seed_history(sources, count: 80_000, created_at: now - 1.day)
    seed_history(sources, count: 20_000, created_at: now - 40.days, sequence_offset: 80_000)
    connection = ApplicationRecord.lease_connection
    connection.execute("ANALYZE conversation_event_items")

    before = ConversationEventItem.count
    retained_before = ConversationEventItem.where(created_at: (now - 1.day)..).count
    queries = reap_queries do
      ApplicationRecord.transaction(requires_new: true) do
        ConversationEventItems::ReapJob.perform_now
        assert_equal before - ConversationEventItems::ReapJob::BATCH, ConversationEventItem.count
        assert_equal 15_000, ConversationEventItem.older_than(30.days).count
        assert_equal retained_before, ConversationEventItem.where(created_at: (now - 1.day)..).count
        raise ActiveRecord::Rollback
      end
    end
    assert_equal before, ConversationEventItem.count, "measurement must restore the deleted batch"
    assert_equal 1, queries.fetch(:source).length
    assert_equal 1, queries.fetch(:delete).length

    plans = queries.to_h do |kind, captured|
      query = captured.sole
      plan = explain(query)
      puts JSON.generate(operation: "conversation_event_reaping", statement: kind,
        expired: 20_000, retained: 80_000, hosts: sources.length,
        sql: query.first, binds: connection.send(:type_casted_binds, query.last), plan: plan)
      [kind, plan]
    end

    source_plan = plans.fetch(:source)
    assert_match(/\ALimit\s/, source_plan)
    assert_match(/Index (?:Only )?Scan using index_conversation_event_items_on_created_at_and_id/, source_plan)
    assert_match(/actual [^\n]*rows=5000(?:\.0+)? loops=1/, source_plan)
    assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Rows Removed by Filter: [1-9]/, source_plan)

    delete_plan = plans.fetch(:delete)
    assert_match(/conversation_event_items_pkey/, delete_plan)
    assert_no_match(/Seq Scan|Rows Removed by Filter: [1-9]/, delete_plan)
  end

  private

    # Take the payload from real task authoring. Hosted and standalone loops
    # contribute their actual source identities; no payload padding is needed.
    def narration_sources
      Array.new(8) do |index|
        agent_loop = if index < 4
          conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
          hosted = create_loop_backed_turn(conversation: conversation, acting_user: @human,
            loop_status: "pending").agent_loop
          grow!(hosted, tool("inspect", "read_file"))
          hosted
        else
          seed(tool("inspect", "read_file"))
        end
        item = agent_loop.host.conversation_event_items.find_by!(item_type: "task_status")
        { host_type: item.host_type, host_id: item.host_id, payload: item.payload }
      end
    end

    def seed_history(sources, count:, created_at:, sequence_offset: 0)
      count.times.each_slice(1_000) do |ordinals|
        envelopes = ordinals.map do |ordinal|
          source = sources.fetch(ordinal % sources.length)
          { account_id: @workspace.account_id, host_type: source.fetch(:host_type),
            host_id: source.fetch(:host_id), idempotency_key: SecureRandom.uuid_v7,
            created_at: created_at, updated_at: created_at }
        end
        ids = ConversationEvent.insert_all!(envelopes, returning: %w[id]).rows.flatten
        ConversationEventItem.insert_all!(ordinals.each_with_index.map do |ordinal, index|
          source = sources.fetch(ordinal % sources.length)
          { account_id: @workspace.account_id, conversation_event_id: ids.fetch(index),
            host_type: source.fetch(:host_type), host_id: source.fetch(:host_id),
            sequence: sequence_offset + ordinal + 2, item_type: "task_status",
            payload: source.fetch(:payload).merge("task_key" => "inspect-#{sequence_offset + ordinal}"),
            occurred_at: created_at, created_at: created_at, updated_at: created_at }
        end)
      end
    end

    def reap_queries
      queries = { source: [], delete: [] }
      subscriber = lambda do |*, payload|
        next if payload[:cached]

        sql = payload.fetch(:sql)
        kind = if sql.start_with?('SELECT "conversation_event_items"."id"')
          :source
        elsif sql.start_with?('DELETE FROM "conversation_event_items"')
          :delete
        end
        queries.fetch(kind) << [sql.dup, payload.fetch(:binds).dup] if kind
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      queries
    end

    def explain(query)
      sql, binds = query
      plan = nil
      ApplicationRecord.transaction(requires_new: true) do
        plan = ApplicationRecord.lease_connection.select_values(
          "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
        ).join("\n")
        raise ActiveRecord::Rollback
      end
      plan
    end
end
