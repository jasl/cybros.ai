require "test_helper"

# The recurring bucket drain: every receipt contributes to
# the hour AND month buckets exactly once, late arrivals fold into their
# historical rows, and the drain never touches the summary plane.
class ModelUsageRollups::BackfillHourlyTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
  end

  test "drains unrolled receipts into hour and month buckets and flags them" do
    receipt = build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15),
      input_tokens: 100, output_tokens: 10, total_tokens: 110,
      cost_amount: BigDecimal("0.1"))
    build_receipt(idempotency_key: "rollup-test:2", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 10, 45), input_tokens: 50, total_tokens: 50,
      cost_amount: BigDecimal("0.2"))

    pass = ModelUsageRollups::BackfillHourly.call
    assert_equal 2, pass[:processed]

    hour = ModelUsageTimeBucket.find_by!(bucket_kind: "hour")
    assert_equal Time.utc(2026, 8, 21, 10), hour.bucket_start_at,
      "10:15 and 10:45 floor into the same UTC hour"
    assert_equal 2, hour.request_count
    assert_equal 150, hour.input_tokens
    assert_equal 160, hour.total_tokens
    assert_equal BigDecimal("0.3"), hour.cost_amount, "decimal money, exact"
    assert_equal 2, hour.cost_known_request_count
    assert_equal receipt.provider_id, hour.provider_id

    month = ModelUsageTimeBucket.find_by!(bucket_kind: "month")
    assert_equal Time.utc(2026, 8, 1), month.bucket_start_at
    assert_equal 2, month.request_count
    assert_equal 0, UsageRecord.where(hourly_rolled_up_at: nil).count
  end

  test "a second run is a no-op: the flag is the cursor" do
    build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100)
    assert_equal 1, ModelUsageRollups::BackfillHourly.call[:processed]
    assert_equal 0, ModelUsageRollups::BackfillHourly.call[:processed]

    assert_equal 100, ModelUsageTimeBucket.find_by!(bucket_kind: "hour").input_tokens,
      "counters did not double"
  end

  test "a late-arriving receipt folds into its historical bucket rows" do
    build_receipt(
      recorded_at: Time.utc(2026, 8, 21, 10, 15),
      input_tokens: 100, cache_read_tokens: 10, cache_creation_tokens: 20,
      output_tokens: 30, reasoning_tokens: 5, total_tokens: 130,
      cost_amount: BigDecimal("0.1")
    )
    ModelUsageRollups::BackfillHourly.call

    build_receipt(idempotency_key: "rollup-test:late", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 10, 59),
      input_tokens: 30, cache_read_tokens: 3, cache_creation_tokens: 4,
      output_tokens: 10, reasoning_tokens: 2, total_tokens: 40,
      cost_amount: BigDecimal("0.2"))
    ModelUsageRollups::BackfillHourly.call

    assert_equal 1, ModelUsageTimeBucket.where(bucket_kind: "hour").count,
      "no watermark to miss behind: the old hour row is incremented, never duplicated"
    hour = ModelUsageTimeBucket.find_by!(bucket_kind: "hour")
    assert_equal 2, hour.request_count
    assert_equal 130, hour.input_tokens
    assert_equal 13, hour.cache_read_tokens
    assert_equal 24, hour.cache_creation_tokens
    assert_equal 40, hour.output_tokens
    assert_equal 7, hour.reasoning_tokens
    assert_equal 170, hour.total_tokens
    assert_equal BigDecimal("0.3"), hour.cost_amount
    assert_equal 2, hour.cost_known_request_count
  end

  test "dimension divergence splits bucket rows; the drain never touches summaries" do
    # A REAL subject with a standing summary: a subjectless receipt would
    # make the not-touched assertion vacuous (item-7 review).
    DevModelLane.ensure_enabled!(@account)
    one_shot = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: @member,
      workload: "text_generation"
    )
    first = build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15),
      one_shot_public_id: one_shot.public_id)
    ModelUsageSummary.increment_for_usage_record(first)
    build_receipt(idempotency_key: "rollup-test:2", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 10, 20), status: "failed",
      one_shot_public_id: one_shot.public_id)

    ModelUsageRollups::BackfillHourly.call

    statuses = ModelUsageTimeBucket.where(bucket_kind: "hour").order(:status).pluck(:status)
    assert_equal %w[failed succeeded], statuses
    summary = ModelUsageSummary.sole
    assert_equal 1, summary.request_count,
      "the summary plane moves with the receipt write, not with this drain — the drained " \
      "second receipt did not reach the standing summary"
  end

  test "buckets apply in sorted bucket-then-key order so overlapping drains cannot deadlock" do
    records = [
      build_receipt(recorded_at: Time.utc(2026, 8, 21, 11, 10)),
      build_receipt(idempotency_key: "rollup-test:2", attempt_ordinal: 2,
        recorded_at: Time.utc(2026, 8, 21, 10, 10)),
      build_receipt(idempotency_key: "rollup-test:3", attempt_ordinal: 3,
        recorded_at: Time.utc(2026, 8, 21, 10, 40), status: "failed"),
    ]

    rows = nil
    capture = ->(attributes, **_options) { rows = attributes }
    ModelUsageTimeBucket.stub(:upsert_all, capture) do
      ModelUsageTimeBucket.increment_for_usage_records(
        records, bucket_kind: "hour", rolled_up_at: Time.current
      )
    end

    applied = rows.map { |row| [row.fetch(:bucket_start_at), row.fetch(:aggregation_key)] }
    assert_equal applied.sort, applied, "the INSERT order IS the sorted lock order"
    assert_equal Time.utc(2026, 8, 21, 10), applied.first.first
  end

  test "rollup query count stays flat as bucket cardinality grows" do
    build_receipt(recorded_at: Time.utc(2026, 8, 21, 10), billing_subject_key: "scale:one")

    single_queries = rollup_query_count do
      assert_equal 1, ModelUsageRollups::BackfillHourly.call[:processed]
    end

    20.times do |index|
      build_receipt(
        idempotency_key: "rollup-scale:#{index}", attempt_ordinal: index + 2,
        recorded_at: Time.utc(2026, 8, 21, 10), billing_subject_key: "scale:#{index}"
      )
    end
    batch_queries = rollup_query_count do
      assert_equal 20, ModelUsageRollups::BackfillHourly.call[:processed]
    end

    assert_operator batch_queries, :<=, single_queries + 1,
      "bucket cardinality must change rows in the upsert, not add per-bucket SQL"
  end

  test "the aggregation key is tenant-complete: account is a dimension" do
    dimensions = ModelUsageTimeBucket::DIMENSION_COLUMNS.index_with { nil }
      .merge(account_id: @account.id, provider_id: "dev",
        catalog_model_ref: "m", workload: "text_generation", status: "succeeded",
        consumer_user_public_id: @member.public_id)

    ours = ModelUsageTimeBucket.aggregation_key_for(dimensions)
    theirs = ModelUsageTimeBucket.aggregation_key_for(dimensions.merge(account_id: @account.id + 1))
    assert_not_equal ours, theirs,
      "two accounts with identical dimension values must never share a bucket row"
  end

  test "the drain is on the recurring schedule in every environment" do
    entry = recurring_schedule.fetch("roll_up_model_usage_hourly")
    assert_equal ModelUsageRollups::HourlyJob.name, entry.fetch("class")
    assert_equal "every 5 minutes", entry.fetch("schedule")
    assert_equal recurring_schedule, recurring_schedule("development")
  end

  private

    def build_receipt(**overrides)
      UsageRecord.create!(
        account: @account, idempotency_key: "rollup-test:1",
        model_invocation_public_id: SecureRandom.uuid_v7,
        attempt_ordinal: 1, consumer_user_public_id: @member.public_id,
        payer_user_public_id: @member.public_id,
        workspace_public_id: workspaces(:shared).public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "one_shot_attempt", service_class: "interactive",
        admission_shape: "priced", status: "succeeded",
        recorded_at: Time.current, cost_unit: "USD",
        **overrides
      )
    end

    def rollup_query_count
      connection = ActiveRecord::Base.lease_connection
      connection.materialize_transactions
      connection.clear_query_cache
      count = 0
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      count
    end
end
