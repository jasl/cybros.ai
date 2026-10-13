require "minitest/autorun"
require_relative "../lib/calc"

class CalcTest < Minitest::Test
  def test_adds = assert_equal(3, Calc.add(1, 2))
  def test_subtracts = assert_equal(1, Calc.sub(3, 2))
end
