require "test_helper"

class BudgetPagesTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @admin = users(:owner)
    @account = accounts(:cybros)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    sign_in_as @human
  end

  test "personal balance is read only and preserves exact negative headroom" do
    mine = open_budget(@human, amount: "1.000000000000000001")
    mine.update_columns(debited_amount: BigDecimal("2"))
    other = open_budget(@admin, amount: "500")
    get settings_budgets_path
    assert_response :success
    assert_select "turbo-frame#settings"
    assert_select "dd", text: "-0.999999999999999999"
    assert_select "dd", text: "1.000000000000000001"
    assert_select "a", text: "Open budget window", count: 0
    assert_not_includes response.body, other.public_id
    get settings_budget_path(mine.public_id)
    assert_response :success
    assert_select "a", text: "Adjust amount", count: 0
    assert_select "turbo-frame#settings form[method=post]", count: 0
    get settings_budget_path(other.public_id)
    assert_response :not_found
  end

  test "current window is separate from bounded history and revoked windows remain readable" do
    past = open_budget(@human, starts_at: 3.days.ago, expires_at: 2.days.ago)
    current = open_budget(@human, starts_at: 1.day.ago, expires_at: 1.day.from_now)
    future = open_budget(@human, starts_at: 2.days.from_now)
    get settings_budgets_path(limit: 1)
    assert_response :success
    assert_select "a[href=?]", settings_budget_path(current.public_id), text: "View window and ledger"
    assert_select "article a", text: past.public_id
    next_path = css_select("nav a").find { |link| link.text == "Next page" }["href"]
    get next_path
    assert_response :success
    assert_select "article a", text: current.public_id
    assert_select "a", text: "First page"
    get settings_budgets_path(limit: 1, order: "desc")
    assert_select "article a", text: future.public_id
    UsageBudgets::Revoke.call(actor: @admin, budget: current, operation_key: "revoke-current", reason: "Closed")
    get settings_budgets_path
    assert_includes response.body, I18n.t("budget_console.uncapped")
    get settings_budget_path(current.public_id)
    assert_response :success
    assert_includes response.body, "Closed"
  end

  test "financial entries paginate without exposing receipt identities or settlement operation keys" do
    budget = open_budget(@human)
    UsageBudgets::Adjust.call(actor: @admin, budget: budget, kind: :credit, amount: "2",
      operation_key: "human-adjustment-key", reason: "Correction")
    receipt_id = SecureRandom.uuid_v7
    budget.entries.create!(account_public_id: @account.public_id, user_public_id: @human.public_id,
      entry_sequence: 3, kind: "charge", amount: "0.25", cost_unit: "USD",
      operation_key: "settle:#{receipt_id}", usage_record_public_id: receipt_id)
    get settings_budget_path(budget.public_id, limit: 1, order: "desc")
    assert_response :success
    assert_select "article h3", text: "3 · Model cost"
    assert_not_includes response.body, receipt_id
    assert_not_includes response.body, "settle:"
    assert_not_includes response.body, "human-adjustment-key"
    next_path = css_select("nav a").find { |link| link.text == "Next page" }["href"]
    get next_path
    assert_select "article h3", text: "2 · Credit adjustment"
    assert_includes response.body, @admin.public_id
    assert_includes response.body, "Correction"
  end

  test "invalid pagination is an explicit error rather than an empty balance" do
    get settings_budgets_path(limit: 101)
    assert_response :bad_request
    assert_select "[role=alert]", text: /Invalid parameter: limit/
    assert_not_includes response.body, I18n.t("budget_console.uncapped")
    get settings_budgets_path(after: "broken")
    assert_response :bad_request
    assert_select "[role=alert]", text: /Invalid parameter: after/
  end

  test "ordinary stewards manage paired and named Agent allowances through the same commands" do
    paired = create_agent_member(steward: @human)
    named = @account.users.create!(kind: :agent, role: :member, steward: @human,
      display_name: "Named", agent_identifier: "#{paired.agent_identifier}/named",
      derived_from: paired, named_agent_scope: :instance, description: "Worker")
    [paired, named].each do |agent|
      get agent_budgets_path(agent)
      assert_response :success
      assert_select "h1", text: "#{agent.display_name} · Budgets"
      assert_includes response.body, I18n.t("budget_console.allowance_coverage")
      get new_agent_budget_path(agent)
      assert_response :success
      key = css_select("input[name='budget[operation_key]']").sole["value"]
      payload = { amount: "2.000000000000000001", starts_at: 1.minute.ago.iso8601(6), operation_key: key }
      post agent_budgets_path(agent), params: { budget: payload }
      assert_response :see_other
      budget = agent.usage_budgets.sole
      assert_redirected_to agent_budget_path(agent, budget.public_id)
      post agent_budgets_path(agent), params: { budget: payload }
      assert_response :see_other
      assert_equal 1, agent.usage_budgets.count
      patch agent_budget_path(agent, budget.public_id), params: {
        budget: { kind: "credit", amount: "1", operation_key: "adjust-#{agent.public_id}", reason: "Top-up" },
      }
      assert_response :see_other
      assert_equal BigDecimal("3.000000000000000001"), budget.reload.headroom
      post agent_budget_revocation_path(agent, budget.public_id), params: {
        revocation: { reason: "No cap", operation_key: "revoke-#{agent.public_id}" },
      }
      assert_response :see_other
      assert_predicate budget.reload, :revoked?
    end
  end

  test "another steward or an unrelated admin cannot read Agent allowance" do
    agent = create_agent_member(steward: @human)
    budget = open_budget(agent, actor: @human)
    sign_out
    sign_in_as @admin
    get agent_budgets_path(agent)
    assert_response :not_found
    patch agent_budget_path(agent, budget.public_id), params: { budget: { kind: "credit", amount: "1", operation_key: "foreign" } }
    assert_response :not_found
    get admin_user_budgets_path(agent)
    assert_response :not_found
    assert_equal BigDecimal("10"), budget.reload.headroom
  end

  test "admin Human management does not accept an Agent target even for its steward" do
    get admin_user_budgets_path(@human)
    assert_response :forbidden
    sign_out
    sign_in_as @admin
    get admin_user_budgets_path(users(:agent))
    assert_response :not_found
    get new_admin_user_budget_path(@human)
    assert_response :success
    post admin_user_budgets_path(@human), params: { budget: {
      amount: "8.25", starts_at: 1.minute.ago.iso8601, expires_at: "", operation_key: "admin-open", reason: "Allocation",
    } }
    assert_response :see_other
    budget = @human.usage_budgets.sole
    get admin_user_budget_path(@human, budget.public_id)
    assert_response :success
    assert_select "a[href=?]", edit_admin_user_budget_path(@human, budget.public_id), text: "Adjust amount"
    assert_select "form[action=?]", admin_user_budget_revocation_path(@human, budget.public_id)
  end

  test "failed open retains exact form input and key including malformed timestamps" do
    agent = create_agent_member(steward: @human)
    payload = { amount: "0.0000000000000000001", starts_at: "bad-time", expires_at: "",
      operation_key: "retained-key", reason: "<script>draft</script>" }
    post agent_budgets_path(agent), params: { budget: payload }
    assert_response :bad_request
    assert_select "input[name='budget[amount]'][value=?]", payload[:amount]
    assert_select "input[name='budget[starts_at]'][value='bad-time']"
    assert_select "input[name='budget[operation_key]'][value='retained-key']"
    assert_select "textarea[name='budget[reason]']", text: payload[:reason]
    assert_select "script", text: "draft", count: 0
    post agent_budgets_path(agent), params: { budget: payload.merge(starts_at: Time.current.iso8601) }
    assert_response :unprocessable_entity
    assert_select "input[name='budget[operation_key]'][value='retained-key']"
    assert_empty agent.usage_budgets
  end

  test "budget dates use UTC controls with seconds and retain the chosen window after a refused amount" do
    agent = create_agent_member(steward: @human)
    get new_agent_budget_path(agent)
    assert_response :success
    assert_select "input[name='budget[starts_at]'][type=datetime-local][step='1']" do |fields|
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/, fields.sole["value"])
    end
    assert_select "input[name='budget[expires_at]'][type=datetime-local][step='1']:not([required])"
    key = css_select("input[name='budget[operation_key]']").sole["value"]
    payload = { amount: "-1", starts_at: "2026-10-18T14:40:15", expires_at: "2026-10-18T15:40:30", operation_key: key }
    post agent_budgets_path(agent), params: { budget: payload }
    assert_response :unprocessable_entity
    assert_select "input[name='budget[starts_at]'][value=?]", payload[:starts_at]
    assert_select "input[name='budget[expires_at]'][value=?]", payload[:expires_at]
    assert_select "input[name='budget[operation_key]'][value=?]", key
    post agent_budgets_path(agent), params: { budget: payload.merge(amount: "2.000000000000000001") }
    assert_response :see_other
    budget = agent.usage_budgets.sole
    assert_equal Time.utc(2026, 10, 18, 14, 40, 15), budget.starts_at
    assert_equal Time.utc(2026, 10, 18, 15, 40, 30), budget.expires_at
    assert_equal BigDecimal("2.000000000000000001"), budget.headroom
  end

  test "adjustment replay cannot duplicate money and conflicts retain the original key and fields" do
    agent = create_agent_member(steward: @human)
    budget = open_budget(agent, actor: @human)
    payload = { kind: "credit", amount: "1.000000000000000001", operation_key: "adjust", reason: "Correction" }
    2.times { patch agent_budget_path(agent, budget.public_id), params: { budget: payload } }
    assert_response :see_other
    assert_equal BigDecimal("11.000000000000000001"), budget.reload.headroom
    assert_equal 2, budget.entries.count
    patch agent_budget_path(agent, budget.public_id), params: { budget: payload.merge(amount: "2") }
    assert_response :conflict
    assert_select "input[name='budget[operation_key]'][value='adjust']"
    assert_select "input[name='budget[amount]'][value='2']"
    assert_select "textarea[name='budget[reason]']", text: "Correction"
    patch agent_budget_path(agent, budget.public_id), params: { budget: payload.merge(kind: "debit", amount: "100", operation_key: "overdraw") }
    assert_response :conflict
    assert_select "select[name='budget[kind]'] option[selected][value=debit]"
    assert_equal 2, budget.entries.count
  end

  test "revocation replay and refusal preserve the request while expired or revoked deficits remain adjustable" do
    agent = create_agent_member(steward: @human)
    budget = open_budget(agent, actor: @human, starts_at: 3.days.ago, expires_at: 2.days.ago)
    budget.update_columns(debited_amount: BigDecimal("11"))
    payload = { operation_key: "revoke", reason: "Close cap" }
    2.times { post agent_budget_revocation_path(agent, budget.public_id), params: { revocation: payload } }
    assert_response :see_other
    post agent_budget_revocation_path(agent, budget.public_id), params: { revocation: payload.merge(reason: "Changed") }
    assert_response :conflict
    assert_select "input[name='revocation[operation_key]'][value='revoke']"
    assert_select "textarea[name='revocation[reason]']", text: "Changed"
    patch agent_budget_path(agent, budget.public_id), params: { budget: { kind: "credit", amount: "1", operation_key: "repair" } }
    assert_response :see_other
    assert_equal BigDecimal("0"), budget.reload.headroom
    assert_equal "Close cap", budget.revoke_reason
  end

  test "a budget UUID from another target and an anonymous mutation do not authorize writes" do
    agent = create_agent_member(steward: @human)
    other = open_budget(@admin)
    get agent_budget_path(agent, other.public_id)
    assert_response :not_found
    sign_out
    assert_no_difference "UsageBudget.count" do
      post agent_budgets_path(agent), params: { budget: { amount: "1", starts_at: Time.current.iso8601, operation_key: "anonymous" } }
    end
    assert_redirected_to new_session_path
  end

  private

    def open_budget(target, actor: @admin, amount: "10", starts_at: 1.minute.ago, expires_at: nil)
      result = UsageBudgets::Open.call(actor: actor, target: target, amount: amount,
        starts_at: starts_at, expires_at: expires_at, operation_key: SecureRandom.uuid_v7)
      assert_predicate result, :opened?
      result.budget
    end
end
