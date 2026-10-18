require "test_helper"
require_relative "../support/contract_fixtures"

class ApiUsageAnalysisTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("analyses.json")

  def test_member_analysis_keeps_scope_filters_exact_money_percentiles_and_retention_denominators
    result = member(pack.fetch("valid_member_fixture")).work.analysis(
      workspace_public_id: "workspace", agent_public_id: "agent", from: "2026-10-15T00:00:00.123456Z",
      to: "2026-10-16T00:00:00.123456Z", group_by: "provider_id", rank_by: "cost_amount", limit: 5,
      provider_id: "dev", catalog_model_ref: "dev/model", workload: "text_generation", status: "succeeded")
    params = @transport.requests.first.fetch(:params)
    assert_equal "/agent_api/v1/work_analysis", @transport.requests.first.fetch(:path)
    assert_equal "workspace", params.fetch("workspace_public_id")
    assert_equal "agent", params.fetch("agent_public_id")
    assert_equal "2026-10-15T00:00:00.123456Z", params.fetch("from")
    assert_equal "cost_amount", params.fetch("rank_by")
    assert_equal 5, params.fetch("limit")
    assert_equal "dev/model", params.fetch("catalog_model_ref")
    assert_equal "text_generation", params.fetch("workload")
    assert_equal "succeeded", params.fetch("status")
    assert_model_usage(result.model_usage)
    assert_equal 2, result.execution.run_count
    assert_equal 2, result.execution.retained_run_count
    assert_equal 0, result.execution.details_pruned_run_count
    assert_equal 1, result.execution.delivered_count
    assert_equal 1, result.execution.undelivered_count
    assert_equal 42, result.execution.latency.delivery_ms.p95
    assert_equal "read_file", result.execution.tools.groups.first.tool_name
    assert_equal 1, result.execution.tools.groups.first.error_result_count
    assert_equal 1, result.execution.tools.groups.first.latency.missing_count
    assert_equal 0, result.execution.tools.other_task_count
  end

  def test_admin_analysis_exposes_account_aggregates_without_member_selectors
    result = platform(pack.fetch("valid_admin_fixture")).model_usage.analysis(
      from: "2026-10-15T00:00:00Z", to: "2026-10-16T00:00:00Z", group_by: "workload", rank_by: "total_tokens",
      limit: 2, provider_id: "dev", catalog_model_ref: "dev/model", workload: "text_generation", status: "abandoned")
    assert_equal "/api/v1/admin/model_usage/analysis", @transport.requests.first.fetch(:path)
    assert_equal "total_tokens", @transport.requests.first.fetch(:params).fetch("rank_by")
    assert_equal "USD", result.cost_unit
    assert_model_usage(result.model_usage)
    refute result.to_h.key?(:execution)
    error_class = ENV["RBS_TEST_TARGET"] ? RBS::Test::Tester::TypeError : ArgumentError
    assert_raises(error_class) { platform(pack.fetch("valid_admin_fixture")).model_usage.analysis(agent_public_id: "agent") }
  end

  def test_future_group_rank_and_status_words_remain_inspectable
    group = member(pack.fetch("unknown_group_fixture")).work.analysis
    assert_equal "zz_unknown_value", group.model_usage.breakdown.group_by
    rank = platform(pack.fetch("unknown_rank_fixture")).model_usage.analysis
    assert_equal "zz_unknown_value", rank.model_usage.breakdown.rank_by
    statuses = member(pack.fetch("unknown_status_fixture")).work.analysis
    assert_equal 1, statuses.model_usage.status_counts.fetch("zz_unknown_value")
    assert_equal 1, statuses.execution.status_counts.fetch("zz_unknown_value")
    assert_equal 1, statuses.execution.tools.status_counts.fetch("zz_unknown_value")
  end

  def test_missing_cost_is_distinct_from_zero_and_bad_counts_fail_at_the_wire
    body = pack.fetch("valid_member_fixture")
    body.fetch("analysis")["cost_unit"] = nil
    result = member(body).work.analysis
    assert_nil result.cost_unit
    assert_equal 0, result.model_usage.latency.duration_ms.p50
    assert_nil result.model_usage.latency.time_to_first_token_ms.p50
    body.fetch("analysis").fetch("model_usage").fetch("status_counts")["succeeded"] = "two"
    assert_raises(CybrosAgent::Api::MalformedResponse) { member(body).work.analysis }
  end

  private

    def member(body)
      @transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::Client.new(base_url: "https://nexus.example", credential: "member-key", transport: @transport)
    end

    def platform(body)
      @transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-key", transport: @transport)
    end

    def assert_model_usage(usage)
      assert_equal "0.040500000000000001", usage.totals.cost_amount
      refute usage.totals.cost_complete
      assert_equal 2, usage.totals.amount_sample_count
      assert_equal 0, usage.latency.duration_ms.p50
      assert_equal 260, usage.latency.duration_ms.p95
      assert_equal 1, usage.latency.duration_ms.missing_count
      assert_equal 0, usage.latency.time_to_first_token_ms.sample_count
      assert_nil usage.latency.time_to_first_token_ms.p95
      assert_equal "dev", usage.breakdown.groups.first.value
      assert_equal 2, usage.breakdown.total_group_count
      assert_equal 1, usage.breakdown.other.request_count
    end
end
