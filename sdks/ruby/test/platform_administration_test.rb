require "test_helper"
require_relative "support/contract_fixtures"

class PlatformAdministrationTest < Minitest::Test
  def pack(name) = CybrosAgentTest::ContractFixtures.pack("platform_#{name}.json")

  def client(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-key", transport: @transport)
  end

  def test_budget_commands_preserve_exact_decimal_strings_and_explicit_operation_keys
    fixture = pack("budgets")
    budgets = client([[201, {}, fixture.fetch("valid_open_fixture")], [200, {}, fixture.fetch("valid_adjust_fixture")],
      [200, {}, fixture.fetch("valid_revoke_fixture")]]).budgets("human/one")
    amount = "10.000000000000000001"
    opened = budgets.open(amount:, starts_at: "2026-10-15T00:00:00Z", expires_at: nil, idempotency_key: "open")
    adjusted = budgets.adjust("budget/one", kind: "credit", amount: "0.000000000000000001", idempotency_key: "adjust")
    revoked = budgets.revoke("budget/one", idempotency_key: "revoke", reason: "Finished")

    assert_equal amount, opened.credited_amount
    assert_equal "0.000000000000000001", adjusted.entry.amount
    assert_equal "2026-10-15T02:00:00Z", revoked.revoked_at
    assert_equal %w[open adjust revoke], @transport.requests.map { |request| request.fetch(:headers).fetch("Idempotency-Key") }
    assert_equal [:post, :patch, :post], @transport.requests.map { |request| request.fetch(:method) }
    body = @transport.requests.first.fetch(:body).fetch("budget")
    assert_equal amount, body.fetch("amount")
    assert_nil body.fetch("expires_at")
    refute body.key?("reason")
    assert_equal "/api/v1/admin/users/human%2Fone/budgets/budget%2Fone/revocation", @transport.requests.last.fetch(:path)
  end

  def test_budget_unknown_entry_kinds_are_not_confused_with_a_local_balance
    fixture = pack("budgets")
    result = client([[200, {}, fixture.fetch("unknown_entry_kind_fixture")]]).budgets("human")
      .adjust("budget", kind: "credit", amount: "1", idempotency_key: "adjust")
    assert_equal "zz_unknown_value", result.entry.kind
    assert_equal "0.125", result.budget.debited_amount
  end

  def test_usage_report_keeps_exact_money_and_infrastructure_filters
    fixture = pack("usage")
    report = client([[200, {}, fixture.fetch("valid_report_fixture")]]).model_usage.report(
      from: "2026-10-15T00:00:00Z", to: "2026-10-15T01:00:00Z", unit: "hour",
      provider_id: "provider", catalog_model_ref: "provider/model",
      workload: "text_generation", status: "succeeded"
    )
    assert_equal 3, report.totals.request_count
    assert_equal "0.040500000000000001", report.totals.cost_amount
    assert_equal "2026-10-15T00:00:00Z", report.series.first.bucket_start_at
    assert report.totals.cost_complete
    request = @transport.requests.first
    assert_equal "/api/v1/admin/model_usage/report", request.fetch(:path)
    assert_equal "provider/model", request.fetch(:params).fetch("catalog_model_ref")
    assert_equal 7, request.fetch(:params).size
    unknown = client([[200, {}, fixture.fetch("unknown_unit_fixture")]]).model_usage.report(from: "from", to: "to")
    assert_equal "zz_unknown_value", unknown.unit
  end
end
