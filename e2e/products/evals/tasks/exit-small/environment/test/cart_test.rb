require "minitest/autorun"
require "cart"
require "pricing"

class CartTest < Minitest::Test
  def test_a_small_cart_has_no_discount
    cart = Cart.new.add("mug", 10.0, 3)
    assert_in_delta 30.0, cart.total
  end

  def test_five_items_earn_the_first_tier
    cart = Cart.new.add("mug", 10.0, 5)
    assert_in_delta 47.5, cart.total, 0.001,
      "5 items should earn 5%"
  end

  def test_ten_items_earn_the_second_tier
    cart = Cart.new.add("mug", 10.0, 10)
    assert_in_delta 90.0, cart.total, 0.001,
      "10 items should earn 10%"
  end

  def test_twenty_items_earn_the_top_tier
    cart = Cart.new.add("mug", 10.0, 20)
    assert_in_delta 160.0, cart.total, 0.001,
      "20 items should earn 20%"
  end

  def test_tiers_are_reported_directly
    assert_in_delta 0.0, Pricing.discount_rate(4)
    assert_in_delta 0.05, Pricing.discount_rate(5)
    assert_in_delta 0.10, Pricing.discount_rate(10)
    assert_in_delta 0.20, Pricing.discount_rate(20)
  end
end
