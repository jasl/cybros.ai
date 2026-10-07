require "test_helper"

# The statistics reader (Stage 4 item 7): buckets plus the unrolled
# remainder equals raw truth EXACTLY for any aligned window — the invariant
# permanent retention buys — and every malformed window is a typed reject.
class ModelUsageRollups::UsageReportTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
  end

  test "a mixed rolled and unrolled window answers raw truth exactly, zero-filled" do
    build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100,
      total_tokens: 110, cost_amount: BigDecimal("0.1"))
    build_receipt(idempotency_key: "report:2", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 12, 5), input_tokens: 40, total_tokens: 40,
      cost_amount: BigDecimal("0.05"))
    ModelUsageRollups::BackfillHourly.call
    build_receipt(idempotency_key: "report:3", attempt_ordinal: 3,
      recorded_at: Time.utc(2026, 8, 21, 10, 45), input_tokens: 60, total_tokens: 60,
      cost_amount: BigDecimal("0.2"))

    build_receipt(idempotency_key: "report:edge", attempt_ordinal: 4,
      recorded_at: Time.utc(2026, 8, 21, 13), input_tokens: 999)
    # A ROLLED receipt past the edge too: the bucket arm has its own range
    # predicate, and only a 13:00 bucket row can catch it inclusive
    # (item-7 review round two). Rolled by hand so the 10:45 receipt above
    # keeps the window genuinely mixed.
    edge_rolled = build_receipt(idempotency_key: "report:edge-rolled", attempt_ordinal: 5,
      recorded_at: Time.utc(2026, 8, 21, 13, 5), input_tokens: 999,
      hourly_rolled_up_at: Time.current)
    ModelUsageTimeBucket.increment_for_usage_records(
      [edge_rolled], bucket_kind: "hour", rolled_up_at: Time.current
    )

    result = report(from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 13))

    assert_equal :reported, result.outcome
    assert_equal 3, result.series.length, "every hour in the window, quiet ones included"
    assert_equal 200, result.series.sum { |point| point.fetch("input_tokens") },
      "the window is half-open on BOTH arms: the unrolled receipt exactly AT `to` and " \
      "the rolled 13:00 bucket are outside it"
    ten, eleven, twelve = result.series
    assert_equal "2026-08-21T10:00:00Z", ten.fetch("bucket_start_at")
    assert_equal 2, ten.fetch("request_count"),
      "one receipt came from the bucket, one from the unrolled remainder — no double count"
    assert_equal 160, ten.fetch("input_tokens")
    assert_equal "0.3", ten.fetch("cost_amount")
    assert_equal 0, eleven.fetch("request_count"), "a quiet hour reads as zeros, not a hole"
    assert_equal 1, twelve.fetch("request_count")
    assert_equal 3, result.totals.fetch("request_count")
    assert_equal "0.35", result.totals.fetch("cost_amount")
    assert_equal true, result.totals.fetch("cost_complete")
  end

  test "day series group hour buckets; month series read month buckets" do
    build_receipt(recorded_at: Time.utc(2026, 8, 20, 23, 30), input_tokens: 10)
    build_receipt(idempotency_key: "report:2", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 0, 30), input_tokens: 20)
    ModelUsageRollups::BackfillHourly.call

    days = report(from: Time.utc(2026, 8, 20), to: Time.utc(2026, 8, 22), unit: "day")
    assert_equal [10, 20], days.series.map { |point| point.fetch("input_tokens") },
      "23:30 and 00:30 land on opposite sides of the UTC day line"

    months = report(from: Time.utc(2026, 8, 1), to: Time.utc(2026, 9, 1), unit: "month")
    assert_equal 1, months.series.length
    assert_equal 30, months.series.first.fetch("input_tokens")
    assert_equal 2, ModelUsageTimeBucket.where(bucket_kind: "month").first.request_count
  end

  test "dimension filters cut both the buckets and the unrolled remainder" do
    build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100)
    ModelUsageRollups::BackfillHourly.call
    build_receipt(idempotency_key: "report:2", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 10, 45), input_tokens: 60, status: "failed")

    window = { from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11) }
    assert_equal 100, report(**window, filters: { "status" => "succeeded" })
      .totals.fetch("input_tokens")
    failed = report(**window, filters: { "status" => "failed" })
    assert_equal 60, failed.totals.fetch("input_tokens")
    assert_equal true, failed.totals.fetch("cost_complete"),
      "the SQL side speaks the same rule: a costless failure counts vacuously known"
    assert_equal 0, report(**window, filters: { "provider_id" => "nobody" })
      .totals.fetch("input_tokens")
  end

  test "an unanswered priced success reads incomplete through both partitions" do
    build_receipt(recorded_at: Time.utc(2026, 8, 21, 10, 15), input_tokens: 100,
      cost_amount: BigDecimal("0.1"))
    ModelUsageRollups::BackfillHourly.call
    window = { from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11) }
    assert_equal true, report(**window).totals.fetch("cost_complete")

    build_receipt(idempotency_key: "report:unknown", attempt_ordinal: 2,
      recorded_at: Time.utc(2026, 8, 21, 10, 30), cost_amount: nil, cost_unit: nil)

    totals = report(**window).totals
    assert_equal 2, totals.fetch("request_count")
    assert_equal false, totals.fetch("cost_complete"),
      "a priced success the catalog never answered for is UNKNOWN money — the unrolled SQL " \
      "arm must say so, not just the Ruby increment"
  end

  test "an abandoned unknown cost stays incomplete before and after rollup" do
    build_receipt(
      status: UsageRecord::ABANDONED,
      recorded_at: Time.utc(2026, 8, 21, 10, 15),
      cost_amount: nil,
      cost_unit: nil
    )
    window = { from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11) }

    assert_equal false, report(**window).totals.fetch("cost_complete")

    ModelUsageRollups::BackfillHourly.call

    assert_equal false, report(**window).totals.fetch("cost_complete")
  end

  test "non-scalar filter values are refused, never silently widened" do
    assert_equal :filter_invalid,
      report(from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11),
        filters: { "status" => %w[succeeded failed] }).refusal
  end

  test "malformed windows are typed refusals, never approximate answers" do
    aligned = { from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 21, 11) }

    assert_equal :window_invalid,
      report(from: Time.utc(2026, 8, 21, 10, 30), to: aligned[:to]).refusal,
      "an unaligned edge would force an approximate answer; the predecessor's ±1h is not ported"
    assert_equal :window_invalid, report(from: aligned[:to], to: aligned[:from]).refusal
    assert_equal :window_invalid,
      report(from: Time.utc(2026, 8, 21, 10), to: Time.utc(2026, 8, 22), unit: "day").refusal,
      "day windows align to the day line"
    assert_equal :unit_unsupported, report(**aligned, unit: "minute").refusal
    assert_equal :filter_unsupported, report(**aligned, filters: { "account_id" => 1 }).refusal,
      "tenancy is the caller's credential, never a filter"
    assert_equal :window_too_wide,
      report(from: Time.utc(2020, 1, 1), to: Time.utc(2026, 1, 1)).refusal
  end

  private

    # Filters ride as keywords under their wire names, the shape the
    # controller hands the service (`**request.query_parameters`).
    def report(from:, to:, unit: "hour", filters: {})
      ModelUsageRollups::UsageReport.call(
        account: @account, from: from, to: to, unit: unit, **filters
      )
    end

    def build_receipt(**overrides)
      UsageRecord.create!(
        account: @account, idempotency_key: "report:1",
        model_invocation_public_id: SecureRandom.uuid_v7,
        attempt_ordinal: 1, consumer_user_public_id: @member.public_id,
        payer_user_public_id: @member.public_id,
        workspace_public_id: workspaces(:shared).public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "inference_request", service_class: "interactive",
        admission_shape: "priced", status: "succeeded",
        recorded_at: Time.current, cost_unit: "USD",
        **overrides
      )
    end
end
