require "test_helper"

class ModelUsageRollups::BackfillHourlyFrontierTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    @recorded_at = Time.utc(2026, 8, 21, 10, 15)
  end

  test "one pass leaves the next receipt for a later hop and still finds late historical arrivals" do
    ids = receipts(3, prefix: "pending")

    first = ModelUsageRollups::BackfillHourly.call(batch_size: 2)

    assert_equal ids.first(2), UsageRecord.where.not(hourly_rolled_up_at: nil).order(:id).pluck(:id),
      "a service invocation must not drain the next source window"
    assert_equal 2, first[:processed]
    assert_predicate first, :more?
    assert_equal 2, ModelUsageTimeBucket.find_by!(bucket_kind: "hour").request_count
    assert_equal 2, ModelUsageTimeBucket.find_by!(bucket_kind: "month").request_count

    late = receipts(1, prefix: "late", recorded_at: @recorded_at - 1.month)
    second = ModelUsageRollups::BackfillHourly.call(batch_size: 2)
    assert_equal 2, second[:processed]
    assert_predicate second, :more?
    assert UsageRecord.find(late.sole).hourly_rolled_up_at,
      "completion markers, not a time watermark, own discovery"
    assert_equal 4, ModelUsageTimeBucket.where(bucket_kind: "hour").sum(:request_count)
    assert_equal 4, ModelUsageTimeBucket.where(bucket_kind: "month").sum(:request_count)

    empty = ModelUsageRollups::BackfillHourly.call(batch_size: 2)
    assert_equal 0, empty[:processed]
    assert_not_predicate empty, :more?
    assert_equal 4, ModelUsageTimeBucket.where(bucket_kind: "hour").sum(:request_count)
    assert_equal 4, ModelUsageTimeBucket.where(bucket_kind: "month").sum(:request_count)
  end

  test "the recurring job yields after one full window and parks its partial continuation" do
    receipts(1_001, prefix: "backlog")

    assert_enqueued_jobs 1, only: ModelUsageRollups::HourlyJob do
      assert_enqueued_with(job: ModelUsageRollups::HourlyJob, args: []) do
        ModelUsageRollups::HourlyJob.perform_now
        assert_equal 1_000, UsageRecord.where.not(hourly_rolled_up_at: nil).count
        assert_equal 1, UsageRecord.where(hourly_rolled_up_at: nil).count
      end
    end
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: ModelUsageRollups::HourlyJob) do
      ModelUsageRollups::HourlyJob.perform_now
    end
    assert_equal 0, UsageRecord.where(hourly_rolled_up_at: nil).count
    %w[hour month].each do |kind|
      bucket = ModelUsageTimeBucket.find_by!(bucket_kind: kind)
      assert_equal 1_001, bucket.request_count
      assert_equal 3_003, bucket.input_tokens
      assert_equal 4_004, bucket.output_tokens
      assert_equal BigDecimal("125.125"), bucket.cost_amount
    end

    assert_no_enqueued_jobs(only: ModelUsageRollups::HourlyJob) do
      ModelUsageRollups::HourlyJob.perform_now
    end
    assert_equal 1_001, ModelUsageTimeBucket.where(bucket_kind: "hour").sum(:request_count)
  end

  test "a failure writing the month rolls back the hour and receipt markers together" do
    receipts(2, prefix: "atomic")
    increment = ModelUsageTimeBucket.method(:increment_for_usage_records)
    fail_month = lambda do |records, bucket_kind:, rolled_up_at:|
      raise "month write failed" if bucket_kind == "month"

      increment.call(records, bucket_kind: bucket_kind, rolled_up_at: rolled_up_at)
    end

    assert_raises(RuntimeError, "month write failed") do
      ModelUsageTimeBucket.stub(:increment_for_usage_records, fail_month) do
        ModelUsageRollups::BackfillHourly.call
      end
    end
    assert_equal 0, ModelUsageTimeBucket.count
    assert_equal 2, UsageRecord.where(hourly_rolled_up_at: nil).count

    ModelUsageRollups::BackfillHourly.call
    assert_equal 0, UsageRecord.where(hourly_rolled_up_at: nil).count
    %w[hour month].each do |kind|
      assert_equal 2, ModelUsageTimeBucket.find_by!(bucket_kind: kind).request_count
    end
  end

  test "the exact source uses the unrolled frontier above settled history in each hop" do
    # Other rolled-back fixtures leave heap and index pages behind. Give this
    # query-plan fixture its own physical layout within the test transaction.
    ApplicationRecord.lease_connection.execute("TRUNCATE TABLE usage_records")
    receipts(8_000, prefix: "history", hourly_rolled_up_at: Time.current)
    receipts(4_001, prefix: "source")
    ApplicationRecord.lease_connection.execute("ANALYZE usage_records")

    2.times do
      queries = source_queries { ModelUsageRollups::BackfillHourly.call }
      assert_equal 1, queries.length, "each invocation may claim only one source window"
      sql, binds = queries.sole
      # More than a full window remains after this pass, so replaying the
      # exact claim SQL still measures early stopping on a real backlog.
      plan = ApplicationRecord.lease_connection.select_values(
        "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
      ).join("\n")
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index Scan using index_usage_records_on_unrolled/, plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Rows Removed by Filter: [1-9]/, plan)
      assert_match(/actual [^\n]*rows=1000(?:\.0+)? loops=1/, plan)
    end
    assert_equal 2_001, UsageRecord.where(hourly_rolled_up_at: nil).count
  end

  private

    def receipts(count, prefix:, recorded_at: @recorded_at, hourly_rolled_up_at: nil)
      now = Time.current
      UsageRecord.insert_all!(Array.new(count) do |index|
        { account_id: @account.id, idempotency_key: "rollup-frontier:#{prefix}:#{index}",
          model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
          consumer_user_public_id: @member.public_id, payer_user_public_id: @member.public_id,
          workspace_public_id: workspaces(:shared).public_id,
          provider_id: "dev", catalog_model_ref: "dev/text",
          wire_model_id: "text", workload: "text_generation", purpose: "inference_request",
          service_class: "interactive", admission_shape: "priced", status: "succeeded",
          recorded_at: recorded_at, cost_unit: "USD", cost_amount: BigDecimal("0.125"),
          input_tokens: 3, output_tokens: 4, total_tokens: 7,
          hourly_rolled_up_at: hourly_rolled_up_at, created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
    end

    def source_queries
      queries = []
      subscriber = lambda do |*, payload|
        next if payload[:cached]

        sql = payload[:sql]
        if sql.start_with?('SELECT "usage_records".*') && sql.include?("FOR UPDATE SKIP LOCKED")
          queries << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      queries
    end
end
