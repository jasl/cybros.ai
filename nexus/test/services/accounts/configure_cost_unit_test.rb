require "test_helper"

# C2-2 WP1: the sole HTTP-neutral configure-once command for the opaque
# Account cost unit. Validation completes before any SQL; the write is one
# nil-only compare-and-set (never an Account root lock); replay and conflict
# change nothing.
class Accounts::ConfigureCostUnitTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "the first setting wins and trims" do
    result = Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "  USD  ")

    assert_predicate result, :configured?
    assert_equal "USD", @account.reload.cost_unit
  end

  test "a same-value replay is idempotent" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    result = Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    assert_predicate result, :already_configured?
    assert_equal "USD", @account.reload.cost_unit
  end

  test "a different value after configuration is a stable conflict changing nothing" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    result = Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "credits")

    assert_predicate result, :conflict?
    assert_equal "USD", @account.reload.cost_unit
  end

  test "the unit is case-sensitive opaque text: a case-different replay is a conflict" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    assert_predicate Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "usd"),
      :conflict?
  end

  test "blank and overlong values are rejected before any SQL and clear is not expressible" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      sql = event.payload[:sql]
      queries << sql if sql.match?(/\A\s*(UPDATE|INSERT|DELETE)/i)
    end

    assert_predicate Accounts::ConfigureCostUnit.call(account: @account, cost_unit: nil), :invalid?
    assert_predicate Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "   "), :invalid?
    assert_predicate Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "x" * 65), :invalid?

    assert_empty queries, "invalid values must refuse before any mutating SQL"
    assert_nil @account.reload.cost_unit
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "a sixty-four character unit is the accepted boundary" do
    value = "x" * 64

    assert_predicate Accounts::ConfigureCostUnit.call(account: @account, cost_unit: value),
      :configured?
    assert_equal value, @account.reload.cost_unit
  end

  test "the CAS never locks the account root row" do
    locks = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      sql = event.payload[:sql]
      locks << sql if sql.match?(/FOR (NO KEY )?UPDATE/i) && sql.include?("accounts")
    end

    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    assert_empty locks, "the configure-once write is a nil-only CAS, never an Account FOR UPDATE"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
