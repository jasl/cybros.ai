require "test_helper"

class ModelUsageRollups::OverviewTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @from = Time.utc(2026, 9, 1)
    @to = Time.utc(2026, 10, 1)
  end

  test "disposition counts share the total scope and monthly comparisons use calendar boundaries" do
    receipt(status: "succeeded", total_tokens: 10)
    receipt(status: "failed", total_tokens: 2)
    ModelUsageRollups::BackfillHourly.call
    receipt(status: "discarded", total_tokens: 4)
    receipt(status: "abandoned", total_tokens: 6)
    receipt(status: "failed", provider_id: "other", total_tokens: 90)
    receipt(status: "succeeded", recorded_at: Time.utc(2026, 8, 1), total_tokens: 3)

    result = overview("provider_id" => "dev")

    assert_equal :reported, result.outcome
    assert_equal 4, result.report.totals.fetch("request_count")
    assert_equal 22, result.report.totals.fetch("total_tokens")
    assert_equal UsageRecord::STATUSES.index_with(1), result.status_counts
    assert_equal "2026-08-01T00:00:00Z", result.previous.series.first.fetch("bucket_start_at")
    assert_equal 3, result.previous.totals.fetch("total_tokens")
    assert_equal false, result.report.totals.fetch("cost_complete")

    selected = overview("provider_id" => "dev", "status" => "failed")
    assert_equal({ "succeeded" => 0, "failed" => 1, "discarded" => 0, "abandoned" => 0 }, selected.status_counts)
    assert_equal 1, selected.report.totals.fetch("request_count")
  end

  test "unsupported member filters produce the same refusal as the public report" do
    assert_equal :filter_unsupported, overview("consumer_user_public_id" => users(:member).public_id).refusal
    assert_equal :filter_invalid, overview("provider_id" => ["dev"]).refusal
  end

  private

    def overview(filters = {})
      ModelUsageRollups::Overview.call(account: @account, from: @from, to: @to, unit: "month", **filters)
    end

    def receipt(**options)
      UsageRecord.create!(account: @account, idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: users(:member).public_id,
        provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text",
        workload: "text_generation", purpose: "task", service_class: "interactive",
        admission_shape: "priced", recorded_at: @from + 1.day, **options)
    end
end
