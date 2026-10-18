require "test_helper"

class API::V1::BudgetReadsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @admin = users(:owner)
    @account = accounts(:cybros)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @platform = credential(@human, :platform)
    @member = credential(@human, :member)
    @admin_headers = credential(@admin, :platform)
  end

  test "both self planes read only the acting Human and preserve exact deficit" do
    mine = open_budget(@human, amount: "1.000000000000000001")
    mine.update_columns(debited_amount: BigDecimal("2"))
    other = open_budget(@admin, amount: "500")

    [["/api/v1", @platform], ["/agent_api/v1", @member]].each do |prefix, headers|
      get "#{prefix}/profile/budgets", headers: headers
      assert_response :success
      body = response.parsed_body
      assert_equal @human.public_id, body.fetch("user_public_id")
      assert_equal [mine.public_id], body.fetch("budgets").pluck("public_id")
      assert_equal "-0.999999999999999999", body.dig("current_budget", "headroom")
      assert_equal "1.000000000000000001", body.dig("current_budget", "credited_amount")
      assert_equal true, body.dig("current_budget", "usable")
      get "#{prefix}/profile/budgets/#{mine.public_id}", headers: headers
      assert_response :success
      assert response.parsed_body.fetch("measured_at")
      get "#{prefix}/profile/budgets/#{other.public_id}", headers: headers
      assert_response :not_found
    end
  end

  test "the current window is independent of the requested history page" do
    past = open_budget(@human, starts_at: 3.days.ago, expires_at: 2.days.ago)
    current = open_budget(@human, starts_at: 1.day.ago, expires_at: 1.day.from_now)
    future = open_budget(@human, starts_at: 2.days.from_now)

    get "/api/v1/profile/budgets", headers: @platform, params: { limit: 1 }
    assert_response :success
    assert_equal [past.public_id], response.parsed_body.fetch("budgets").pluck("public_id")
    assert_equal current.public_id, response.parsed_body.dig("current_budget", "public_id")
    assert_equal false, response.parsed_body.fetch("budgets").sole.fetch("usable")
    cursor = response.parsed_body.dig("pagination", "next_after")
    get "/api/v1/profile/budgets", headers: @platform, params: { limit: 1, after: cursor }
    assert_equal [current.public_id], response.parsed_body.fetch("budgets").pluck("public_id")
    get "/api/v1/profile/budgets", headers: @platform, params: { limit: 1, order: "desc" }
    assert_equal [future.public_id], response.parsed_body.fetch("budgets").pluck("public_id")
    assert_equal current.public_id, response.parsed_body.dig("current_budget", "public_id")
  end

  test "revoked and absent windows have no current cap" do
    get "/api/v1/profile/budgets", headers: @platform
    assert_response :success
    assert_nil response.parsed_body.fetch("current_budget")
    assert_empty response.parsed_body.fetch("budgets")

    budget = open_budget(@human)
    UsageBudgets::Revoke.call(actor: @admin, budget: budget, operation_key: "revoke", reason: "Close cap")
    get "/api/v1/profile/budgets", headers: @platform
    assert_nil response.parsed_body.fetch("current_budget")
    row = response.parsed_body.fetch("budgets").sole
    assert_equal false, row.fetch("usable")
    assert_equal @admin.public_id, row.fetch("revoked_by_public_id")
    assert_equal "Close cap", row.fetch("revoke_reason")
  end

  test "financial ledger reads hide machine receipt keys and paginate sequence in both directions" do
    budget = open_budget(@human)
    2.times do |index|
      UsageBudgets::Adjust.call(actor: @admin, budget: budget, kind: :credit, amount: "1",
        operation_key: "credit-#{index}", reason: "Correction")
    end
    receipt_id = SecureRandom.uuid_v7
    budget.entries.create!(account_public_id: @account.public_id, user_public_id: @human.public_id,
      entry_sequence: 4, kind: "charge", amount: "0.25", cost_unit: "USD",
      operation_key: "settle:#{receipt_id}", usage_record_public_id: receipt_id)
    path = "/api/v1/profile/budgets/#{budget.public_id}/entries"
    %w[asc desc].each do |direction|
      sequences = []
      cursor = nil
      loop do
        get path, headers: @platform, params: { limit: 1, order: direction, after: cursor }
        assert_response :success
        row = response.parsed_body.fetch("entries").sole
        assert_equal %w[actor_public_id amount cost_unit created_at kind public_id reason sequence], row.keys.sort
        assert_not_includes response.body, receipt_id
        assert_not_includes response.body, "operation_key"
        sequences << row.fetch("sequence")
        cursor = response.parsed_body.dig("pagination", "next_after")
        break if cursor.nil?
      end
      assert_equal(direction == "asc" ? [1, 2, 3, 4] : [4, 3, 2, 1], sequences)
    end
    get path, headers: @platform, params: { limit: 1 }
    cursor = response.parsed_body.dig("pagination", "next_after")
    get path, headers: @platform, params: { order: "desc", after: cursor }
    assert_response :bad_request
    malformed = Base64.urlsafe_encode64(JSON.generate(dir: "asc", entry_sequence: "not-an-integer"))
    get path, headers: @platform, params: { after: malformed }
    assert_response :bad_request
    overflow = Base64.urlsafe_encode64(JSON.generate(dir: "asc", entry_sequence: "9" * 30))
    get path, headers: @platform, params: { after: overflow }
    assert_response :bad_request
  end

  test "an ordinary steward can manage both paired and named Agent allowances" do
    paired = create_agent_member(steward: @human)
    named = @account.users.create!(kind: :agent, role: :member, steward: @human,
      display_name: "Named", agent_identifier: "#{paired.agent_identifier}/named",
      derived_from: paired, named_agent_scope: :instance, description: "Worker")
    [paired, named].each do |agent|
      path = "/api/v1/agents/#{agent.public_id}/budgets"
      headers = @platform.merge("Idempotency-Key" => "open-#{agent.public_id}")
      payload = { budget: { amount: "2.000000000000000001", starts_at: 1.minute.ago.iso8601 } }
      post path, headers: headers, params: payload, as: :json
      assert_response :created
      budget_id = response.parsed_body.dig("budget", "public_id")
      post path, headers: headers, params: payload, as: :json
      assert_response :created
      assert_equal budget_id, response.parsed_body.dig("budget", "public_id")
      get path, headers: @platform
      assert_response :success
      assert_equal "agent", response.parsed_body.fetch("user_kind")
      get "#{path}/#{budget_id}/entries", headers: @platform
      assert_response :success
      patch "#{path}/#{budget_id}", headers: @platform.merge("Idempotency-Key" => "adjust"),
        params: { budget: { kind: "credit", amount: "1" } }, as: :json
      assert_response :success
      assert_equal "3.000000000000000001", response.parsed_body.dig("budget", "headroom")
      post "#{path}/#{budget_id}/revocation", headers: @platform.merge("Idempotency-Key" => "revoke"),
        params: { revocation: { reason: "No cap" } }, as: :json
      assert_response :success
      assert_equal false, response.parsed_body.dig("budget", "usable")
      get path, headers: @admin_headers
      assert_response :not_found, "an unrelated admin is not the steward"
      get "/api/v1/admin/users/#{agent.public_id}/budgets", headers: @admin_headers
      assert_response :not_found
    end
  end

  test "Agent self reads its allowance without access to the steward balance" do
    agent = create_agent_member(steward: @human)
    own = open_budget(agent, actor: @human)
    human = open_budget(@human)
    post "/api/v1/agents/#{agent.public_id}/api_keys", headers: @platform,
      params: { api_key: { name: "Own allowance" } }, as: :json
    assert_response :created
    headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("secret")}" }
    get "/agent_api/v1/profile/budgets", headers: headers
    assert_response :success
    assert_equal agent.public_id, response.parsed_body.fetch("user_public_id")
    assert_equal [own.public_id], response.parsed_body.fetch("budgets").pluck("public_id")
    get "/agent_api/v1/profile/budgets/#{human.public_id}", headers: headers
    assert_response :not_found
    get "/api/v1/profile/budgets", headers: headers
    assert_response :unauthorized
  end

  test "admin money access reads Human amounts without granting member activity access" do
    budget = open_budget(@human)
    path = "/api/v1/admin/users/#{@human.public_id}/budgets"
    get path, headers: @admin_headers
    assert_response :success
    assert_equal [budget.public_id], response.parsed_body.fetch("budgets").pluck("public_id")
    get "#{path}/#{budget.public_id}/entries", headers: @admin_headers
    assert_response :success
    get path, headers: @platform
    assert_response :forbidden
    get "/api/v1/agents/#{@human.public_id}/budgets", headers: @platform
    assert_response :not_found
  end

  private

    def credential(user, plane)
      token = create_access_token_fixture(user: user, name: "Budget reader", plane: plane)
      { "Authorization" => "Bearer #{token.secret}" }
    end

    def open_budget(target, actor: @admin, amount: "10", starts_at: 1.minute.ago, expires_at: nil)
      result = UsageBudgets::Open.call(actor: actor, target: target, amount: amount,
        starts_at: starts_at, expires_at: expires_at, operation_key: SecureRandom.uuid)
      assert_predicate result, :opened?
      result.budget
    end
end
