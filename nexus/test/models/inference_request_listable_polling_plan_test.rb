require "test_helper"

# The public InferenceRequest list is a polling path: it must enter through the current
# Workspace's listable public-id frontier even when retained tombstones and
# other Workspaces dominate the table.
class InferenceRequestListablePollingPlanTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @foreign_workspace = workspaces(:personal)
  end

  test "the polling index matches the production filter and keyset" do
    index = InferenceRequest.connection.indexes(:inference_requests)
      .index_by(&:name)
      .fetch("index_inference_requests_on_workspace_and_listable_public_id")

    assert_equal %w[workspace_id public_id], index.columns
    assert_includes index.where, "tombstoned_at IS NULL"
  end

  test "listable polling enters the partial Workspace keyset index at scale" do
    visible_ids = insert_history(workspace: @workspace, count: 2)
    # Keep retained history dominant inside the target Workspace while other
    # Workspaces dominate the table, as they do for a normal bounded poll.
    # Making the target half the corpus lets independent selectivity estimates
    # price the unrelated global public-id index within planner noise.
    insert_history(workspace: @workspace, count: 400, tombstoned_at: Time.current)
    insert_history(workspace: @foreign_workspace, count: 8_000)
    ApplicationRecord.lease_connection.execute("ANALYZE inference_requests")

    statement = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "inference_requests".* FROM "inference_requests"') && sql.include?("ORDER BY")
        statement ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end
    begin
      records = InferenceRequest.uncached do
        InferenceRequest.where(workspace_id: @workspace.id).listable
          .order(:public_id).limit(26).to_a
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal visible_ids.sort, records.map(&:public_id)
    assert statement, "the production polling relation must execute"
    plan = explain(*statement)
    assert_match(/Limit/, plan)
    assert_match(
      /Index Scan using index_inference_requests_on_workspace_and_listable_public_id/,
      plan
    )
    assert_no_match(/\bSort\b/, plan)
    assert_no_match(/Seq Scan on inference_requests(?:\s|$)/, plan)
  end

  private

    def insert_history(workspace:, count:, tombstoned_at: nil)
      now = Time.current
      rows = Array.new(count) do
        {
          account_id: workspace.account_id,
          workspace_id: workspace.id,
          creating_user_id: workspace.creator_id,
          workload: "text_generation",
          tombstoned_at: tombstoned_at,
          created_at: now,
          updated_at: now,
        }
      end
      inference_requests = InferenceRequest.insert_all!(rows, returning: %w[id public_id]).rows
      inference_requests.map(&:last)
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end
end
