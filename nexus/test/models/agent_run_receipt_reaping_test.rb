require "test_helper"

class AgentRunReceiptReapingTest < ActiveSupport::TestCase
  [AgentRunCreateReceipt, AgentRunAppendReceipt].each do |model|
    test "#{model.name} expiry uses an ordered source window and deletes only its ids" do
      loop_row = AgentRun.create!(workspace: workspaces(:shared), creating_user: users(:member),
        approval_mode: "bypass")
      now = DatabaseClock.now
      insert_receipts(model, loop_row, count: 16_000, created_at: now, prefix: "fresh")
      insert_receipts(model, loop_row, count: 4_000, created_at: now - 25.hours, prefix: "old")
      ApplicationRecord.lease_connection.execute("ANALYZE #{model.table_name}")

      statements = reap_statements(model) do
        ApplicationRecord.transaction(requires_new: true) do
          assert_equal 1_000, model.reap(batch: 1_000)
          assert_equal 3_000, model.older_than(model::RETENTION).count
          raise ActiveRecord::Rollback
        end
      end
      assert_equal 20_000, model.count

      source_plan = explain(statements.fetch(:source))
      assert_match(/\ALimit\s/, source_plan)
      assert_match(/Index (?:Only )?Scan using index_#{model.table_name}_on_created_at_and_id/, source_plan)
      assert_match(/actual [^\n]*rows=1000(?:\.0+)? loops=1/, source_plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Filter:/, source_plan)

      delete_plan = explain(statements.fetch(:delete))
      assert_match(/#{model.table_name}_pkey/, delete_plan)
      assert_no_match(/Seq Scan|Filter:/, delete_plan)
      assert AgentRun.exists?(loop_row.id), "collecting replay evidence never deletes its effect"
    end
  end

  private

    def insert_receipts(model, loop_row, count:, created_at:, prefix:)
      common = { account_id: loop_row.account_id, agent_run_id: loop_row.id, request_digest: "a" * 64 }
      attributes = if model == AgentRunCreateReceipt
        common.merge(workspace_id: loop_row.workspace_id, creating_user_id: loop_row.creating_user_id)
      else
        common.merge(response_status: 201, response_body: {})
      end
      count.times.each_slice(1_000) do |ordinals|
        model.insert_all!(ordinals.map do |ordinal|
          attributes.merge(idempotency_key: "#{prefix}-#{ordinal}",
            created_at: created_at + ordinal.fdiv(1_000), updated_at: created_at)
        end)
      end
    end

    def reap_statements(model)
      statements = {}
      subscriber = lambda do |*, payload|
        next if payload[:cached]

        sql = payload.fetch(:sql)
        kind = if sql.start_with?("SELECT \"#{model.table_name}\".\"id\"")
          :source
        elsif sql.start_with?("DELETE FROM \"#{model.table_name}\"")
          :delete
        end
        statements[kind] = [sql.dup, payload.fetch(:binds).dup] if kind
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      statements
    end

    def explain(statement)
      sql, binds = statement
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
