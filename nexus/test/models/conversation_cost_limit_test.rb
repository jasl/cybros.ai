require "test_helper"

class ConversationCostLimitTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @account.update!(cost_unit: "USD")
    @conversation = Conversation.new(workspace: workspaces(:shared), creating_user: users(:member))
  end

  test "limits preserve exact column precision including zero and nil" do
    [nil, "0", "0.000000000000000001", "99999999999999999999.999999999999999999"].each do |amount|
      @conversation.cost_limit = amount
      assert @conversation.save, @conversation.errors.full_messages.inspect
      amount.nil? ? assert_nil(@conversation.reload.cost_limit) : assert_equal(amount.to_d, @conversation.reload.cost_limit)
    end
  end

  test "malformed and rounded amounts are refused before decimal casting can hide them" do
    ["", "no", "NaN", "Infinity", "-Infinity", "-0.01", "1e20", "0.0000000000000000001"].each do |amount|
      @conversation.cost_limit = amount
      assert_not @conversation.valid?, "accepted #{amount.inspect}"
      assert_includes @conversation.errors.attribute_names, :cost_limit
    end
    assert_not @conversation.persisted?
  end

  test "a non-null limit requires the account cost unit but clearing remains possible" do
    @account.update!(cost_unit: nil)
    @conversation.cost_limit = "0"
    assert_not @conversation.valid?
    assert @conversation.errors.of_kind?(:cost_limit, :cost_unit_unconfigured)
    @conversation.cost_limit = nil
    assert_predicate @conversation, :valid?
  end

  test "the threshold is the known subtotal at or above the configured limit" do
    @conversation.update!(cost_limit: "1")
    assert_not @conversation.cost_limit_reached?
    assert_not @conversation.cost_limit_reached?(cost_amount: "0.999999999999999999")
    assert @conversation.cost_limit_reached?(cost_amount: "1")
    assert @conversation.cost_limit_reached?(cost_amount: "1.1")
    @conversation.update!(cost_limit: "0")
    assert @conversation.cost_limit_reached?
    @conversation.update!(cost_limit: nil)
    assert_not @conversation.cost_limit_reached?(cost_amount: "100")
  end
end
