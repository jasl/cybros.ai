require "minitest/autorun"
require "ledger"

class MoneyTest < Minitest::Test
  def test_adds_and_subtracts_in_cents
    assert_equal Ledger::Money.new(1500), Ledger::Money.new(1000) + Ledger::Money.new(500)
    assert_equal Ledger::Money.new(-250), Ledger::Money.new(250) - Ledger::Money.new(500)
  end

  def test_parses_decimal_text
    assert_equal Ledger::Money.new(1250), Ledger::Money.parse("12.50")
    assert_equal Ledger::Money.new(-105), Ledger::Money.parse("-1.05")
    assert_equal Ledger::Money.new(700), Ledger::Money.parse("7")
  end

  def test_renders_with_two_decimals_and_a_sign
    assert_equal "12.50", Ledger::Money.new(1250).to_s
    assert_equal "-0.05", Ledger::Money.new(-5).to_s
    assert_equal "0.00", Ledger::Money.zero.to_s
  end
end
