require "test_helper"

# Connect/Consume and the Agent management page deliberately consult retained
# terminal executor generations. These production latest-row queries must stop
# at the first matching index entry even when one identity has long history.
class TaskExecutorHistoryLookupPlanTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
    @profile = users(:agent)
    @now = Time.current
  end

  test "latest runner lookup covers identity and descending recency under lock" do
    insert_runner_history(12_000, identifier: "plan-runner")
    insert_runner_history(12_000, identifier: "other-runner")
    ApplicationRecord.lease_connection.execute("ANALYZE task_executors")

    statement = capture_task_executor_select do
      TaskExecutor.registered_as(
        account_id: @account.id,
        manager_id: @manager.id,
        registration_identifier: "plan-runner"
      ).newest_first.lock.first
    end
    assert statement, "the latest-runner lookup must execute the production lock query"
    plan = explain(*statement)

    assert_match(/Limit/, plan)
    assert_match(/Index Scan using index_task_executors_on_runner_identity/, plan)
    assert_no_match(/\bSort\b/, plan)
    assert_no_match(/Seq Scan on task_executors(?:\s|$)/, plan)
  end

  test "latest agent address lookup covers Profile and descending recency under lock" do
    insert_agent_address_history(12_000, profile: @profile)
    other = create_agent_member(
      account: @account, steward: @manager,
      display_name: "Other plan agent", agent_identifier: "other-plan-agent"
    )
    insert_agent_address_history(12_000, profile: other)
    ApplicationRecord.lease_connection.execute("ANALYZE task_executors")

    statement = capture_task_executor_select do
      TaskExecutor.addressing(@profile).newest_first.lock.first
    end
    assert statement, "the latest-address lookup must execute the production lock query"
    plan = explain(*statement)

    assert_match(/Limit/, plan)
    assert_match(/Index Scan using index_task_executors_on_agent_and_recency/, plan)
    assert_no_match(/\bSort\b/, plan)
    assert_no_match(/Seq Scan on task_executors(?:\s|$)/, plan)
  end

  test "history indexes retain leading coverage for both rewritten references" do
    indexes = TaskExecutor.connection.indexes(:task_executors).index_by(&:name)
    account_history = indexes.fetch("index_task_executors_on_runner_identity")
    profile_history = indexes.fetch("index_task_executors_on_agent_and_recency")

    assert_nil account_history.where,
      "the account-leading replacement must cover agent_application rows too"
    assert_equal %w[account_id manager_id registration_identifier created_at id],
      account_history.columns
    assert_equal %w[agent_id created_at id], profile_history.columns
  end

  private

    def insert_runner_history(count, identifier:)
      insert_executor_rows(count) do |index|
        {
          account_id: @account.id,
          manager_id: @manager.id,
          executor_kind: "runner",
          registration_identifier: identifier,
          assignment_scope: "user_private",
          display_name: "Runner history",
          status: "revoked",
          created_at: @now + index.seconds,
          updated_at: @now + index.seconds,
        }
      end
    end

    def insert_agent_address_history(count, profile:)
      insert_executor_rows(count) do |index|
        {
          account_id: @account.id,
          agent_id: profile.id,
          executor_kind: "agent_application",
          display_name: "Address history",
          status: "revoked",
          created_at: @now + index.seconds,
          updated_at: @now + index.seconds,
        }
      end
    end

    def insert_executor_rows(count)
      count.times.each_slice(1_000) do |slice|
        TaskExecutor.insert_all!(slice.map { |index| yield index })
      end
    end

    def capture_task_executor_select
      statement = nil
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if sql.start_with?('SELECT "task_executors".*') && sql.include?("FOR UPDATE")
          statement ||= [sql.dup, payload.fetch(:binds).dup]
        end
      end
      TaskExecutor.uncached { yield }
      statement
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
