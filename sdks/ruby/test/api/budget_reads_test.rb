require "test_helper"
require_relative "../support/contract_fixtures"

class ApiBudgetReadsTest < Minitest::Test
  def pack = CybrosAgentTest::ContractFixtures.pack("platform_budgets.json")

  def test_member_and_platform_self_reads_have_typed_current_history_and_ledger
    [CybrosAgent::Client, CybrosAgent::PlatformClient].each do |client_class|
      base = client_class == CybrosAgent::Client ? "/agent_api/v1" : "/api/v1"
      budgets = client(client_class, reads).profile.budgets
      assert_reads(budgets, "#{base}/profile/budgets")
      refute_respond_to budgets, :open
      refute_respond_to budgets, :adjust
      refute_respond_to budgets, :revoke
    end
  end

  def test_admin_human_and_steward_agent_reads_share_the_amount_contract
    admin = client(CybrosAgent::PlatformClient, reads).budgets("human/one")
    assert_reads(admin, "/api/v1/admin/users/human%2Fone/budgets")
    steward = client(CybrosAgent::PlatformClient, reads).agents.agent("agent/one").budgets
    assert_reads(steward, "/api/v1/agents/agent%2Fone/budgets")
  end

  def test_an_uncapped_current_window_is_not_zero_headroom
    fixture = pack.fetch("valid_uncapped_fixture")
    result = client(CybrosAgent::Client, [[200, {}, fixture]]).profile.budgets.list
    assert_nil result.current_budget
    assert_empty result.items
    assert_nil result.next_after
  end

  def test_steward_commands_keep_exact_money_keys_and_command_entry_identity
    budgets = client(CybrosAgent::PlatformClient, [
      [201, {}, pack.fetch("valid_open_fixture")], [200, {}, pack.fetch("valid_adjust_fixture")],
      [200, {}, pack.fetch("valid_revoke_fixture")],
    ]).agents.agent("agent/one").budgets
    opened = budgets.open(amount: "10.000000000000000001", starts_at: "2026-10-15T00:00:00Z",
      idempotency_key: "open", expires_at: nil)
    adjusted = budgets.adjust(opened.public_id, kind: "credit", amount: "0.000000000000000001",
      idempotency_key: "adjust", reason: "Allowance")
    revoked = budgets.revoke(opened.public_id, idempotency_key: "revoke")

    assert_equal "10.000000000000000001", opened.credited_amount
    assert_equal "0.000000000000000001", adjusted.entry.amount
    assert_equal "credit_adjustment", adjusted.entry.kind
    assert_equal "fixture-budget-adjustment", adjusted.entry.operation_key
    refute revoked.usable
    assert_equal %w[open adjust revoke], @transport.requests.map { |request| request.fetch(:headers).fetch("Idempotency-Key") }
    assert @transport.requests.all? { |request| request.fetch(:path).start_with?("/api/v1/agents/agent%2Fone/budgets") }
    assert_nil @transport.requests.first.fetch(:body).fetch("budget").fetch("expires_at")
  end

  def test_budget_refusals_remain_typed_without_fallback_or_retry
    [[403, CybrosAgent::Api::Forbidden], [404, CybrosAgent::Api::NotFound]].each do |status, error_class|
      budgets = client(CybrosAgent::PlatformClient, [[status, {}, { "error" => { "code" => "not_authorized" } }]])
        .agents.agent("other-agent").budgets
      assert_raises(error_class) { budgets.fetch("window") }
      assert_equal 1, @transport.requests.length
    end
  end

  private

    def client(client_class, script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      client_class.new(base_url: "https://nexus.example", credential: "fixture-key", transport: @transport)
    end

    def reads
      ["valid_list_fixture", "valid_show_fixture", "valid_entries_fixture"].map { |name| [200, {}, pack.fetch(name)] }
    end

    def assert_reads(budgets, path)
      overview = budgets.list(after: "cursor", limit: 2, order: "desc")
      detail = budgets.fetch("window/one")
      entries = budgets.entries("window/one", after: "entry-cursor", limit: 5)

      assert_equal pack.dig("valid_list_fixture", "current_budget", "headroom"), overview.current_budget.headroom
      assert_equal overview.current_budget.public_id, overview.items.first.public_id
      assert_equal "human", overview.user_kind
      assert_equal pack.dig("valid_show_fixture", "measured_at"), detail.measured_at
      assert detail.budget.usable
      entry = entries.items.first
      assert_equal "0.000000000000000001", entry.amount
      assert_equal "credit_adjustment", entry.kind
      assert_equal pack.dig("valid_entries_fixture", "entries", 0, "actor_public_id"), entry.actor_public_id
      refute entry.to_h.key?(:operation_key)
      assert_nil entries.next_after
      assert_equal [path, "#{path}/window%2Fone", "#{path}/window%2Fone/entries"], @transport.requests.map { |request| request.fetch(:path) }
      assert_equal({ "after" => "cursor", "limit" => 2, "order" => "desc" }, @transport.requests.first.fetch(:params))
      assert_equal({ "after" => "entry-cursor", "limit" => 5 }, @transport.requests.last.fetch(:params))
    end
end
