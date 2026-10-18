require "test_helper"

class ModelUsageRollups::AnalysisTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @account = accounts(:cybros)
    @from = Time.utc(2026, 10, 10, 12, 15, 30)
    @to = @from + 1.day
  end

  test "raw attempts keep exact windows, independent latency samples, and recorded amount evidence" do
    receipt(provider_id: "alpha", recorded_at: @from, total_tokens: 10, cost_amount: "0",
      duration_ms: 0, time_to_first_token_ms: nil, hourly_rolled_up_at: Time.current)
    receipt(provider_id: "alpha", total_tokens: 20, cost_amount: "0.25",
      duration_ms: 10, time_to_first_token_ms: 0)
    receipt(provider_id: "beta", total_tokens: nil, cost_amount: nil,
      duration_ms: 100, time_to_first_token_ms: 20)
    receipt(provider_id: "beta", status: "failed", cost_amount: nil,
      duration_ms: nil, time_to_first_token_ms: nil)
    receipt(recorded_at: @from - 0.001, total_tokens: 900)
    receipt(recorded_at: @to, total_tokens: 900)

    result = nil
    assert_no_queries_match(/\ASELECT "usage_records"\.\*/) { result = analyze(limit: 1) }
    assert_equal :reported, result.outcome
    usage = result.report.model_usage
    assert_equal 4, usage.totals.fetch("request_count")
    assert_equal 30, usage.totals.fetch("total_tokens")
    assert_equal "0.25", usage.totals.fetch("cost_amount")
    assert_equal 2, usage.totals.fetch("amount_sample_count")
    assert_equal false, usage.totals.fetch("cost_complete")
    assert_equal({ sample_count: 3, missing_count: 1, p50: 10, p95: 100 }, usage.latency.duration_ms.to_h)
    assert_equal({ sample_count: 2, missing_count: 2, p50: 0, p95: 20 }, usage.latency.time_to_first_token_ms.to_h)
    assert_equal({ "succeeded" => 3, "failed" => 1, "discarded" => 0, "abandoned" => 0 }, usage.status_counts)
    assert_equal 2, usage.breakdown.total_group_count
    assert_equal ["alpha"], usage.breakdown.groups.map(&:value), "equal counts sort by dimension value"
    assert_equal 2, usage.breakdown.other.fetch("request_count")
    assert_equal 0, usage.breakdown.other.fetch("amount_sample_count")
    assert_equal false, usage.breakdown.other.fetch("cost_complete"), "derive from remaining known counts"
    assert_equal @from, result.report.from
    assert_equal @to, result.report.to
  end

  test "all costless failures can be complete without any amount sample" do
    receipt(status: "failed", cost_amount: nil)
    usage = analyze.report.model_usage
    assert_equal true, usage.totals.fetch("cost_complete")
    assert_equal 0, usage.totals.fetch("amount_sample_count")
    assert_equal "0.0", usage.totals.fetch("cost_amount")
    assert_nil usage.latency.duration_ms.p50
    assert_nil usage.latency.duration_ms.p95
    assert_equal 1, usage.latency.duration_ms.missing_count
  end

  test "nearest rank returns observed samples and one sample supplies both percentiles" do
    20.times { |value| receipt(duration_ms: value, provider_id: "alpha") }
    receipt(duration_ms: 777, provider_id: "beta")
    sample = analyze(filters: { "provider_id" => "alpha" }).report.model_usage.latency.duration_ms
    assert_equal 9, sample.p50
    assert_equal 18, sample.p95
    sample = analyze(filters: { "provider_id" => "beta" }).report.model_usage.latency.duration_ms
    assert_equal 777, sample.p50
    assert_equal 777, sample.p95
  end

  test "ranking and all dimensions keep full totals while limiting output" do
    receipt(provider_id: "alpha", catalog_model_ref: "alpha/text", total_tokens: 30, cost_amount: "0.1")
    receipt(provider_id: "beta", catalog_model_ref: "beta/text", total_tokens: 10, cost_amount: "0.3")
    receipt(provider_id: "gamma", catalog_model_ref: "gamma/text", total_tokens: 20, status: "discarded", cost_amount: "0.2")
    usage = analyze(group_by: "catalog_model_ref", rank_by: "cost_amount", limit: 1).report.model_usage
    assert_equal ["beta/text"], usage.breakdown.groups.map(&:value)
    assert_equal 3, usage.totals.fetch("request_count")
    assert_equal "0.6", usage.totals.fetch("cost_amount")
    assert_equal "0.3", usage.breakdown.other.fetch("cost_amount")
    assert_equal true, usage.breakdown.other.fetch("cost_complete")
    assert_equal "alpha", analyze(rank_by: "total_tokens", limit: 1).report.model_usage.breakdown.groups.first.value
    assert_equal %w[discarded succeeded], analyze(group_by: "status").report.model_usage.breakdown.groups.map(&:value).sort
    assert_equal ["text_generation"], analyze(group_by: "workload").report.model_usage.breakdown.groups.map(&:value)
    assert_equal 1, analyze(filters: { "status" => "discarded" }).report.model_usage.totals.fetch("request_count")
  end

  test "quiet windows have no groups or samples and the bound refuses without truncating" do
    result = analyze
    usage = result.report.model_usage
    assert_equal 0, usage.totals.fetch("request_count")
    assert_equal 0, usage.breakdown.total_group_count
    assert_empty usage.breakdown.groups
    assert_equal({ sample_count: 0, missing_count: 0, p50: nil, p95: nil }, usage.latency.duration_ms.to_h)
    assert_equal :reported, analyze(to: @from + 90.days).outcome
    assert_equal :window_too_wide, analyze(to: @from + 90.days + 0.001).refusal
    assert_equal :window_invalid, analyze(to: @from).refusal
    assert_equal :filter_unsupported, analyze(filters: { "workspace_public_id" => "hidden" }).refusal
    assert_equal :filter_invalid, analyze(group_by: "payer_user_public_id").refusal
    assert_equal :filter_invalid, analyze(rank_by: "duration_ms").refusal
    assert_equal :filter_invalid, analyze(limit: 51).refusal
  end

  private

    def analyze(**options)
      ModelUsageRollups::Analysis.call(account: @account, from: @from, to: @to, **options)
    end

    def receipt(**options)
      UsageRecord.create!(account: @account, idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: users(:member).public_id, provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation", purpose: "task", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: @from + 1.hour, cost_unit: "USD", **options)
    end
end
