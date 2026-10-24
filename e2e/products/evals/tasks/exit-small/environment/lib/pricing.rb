module Pricing
  TIERS = [[20, 0.20], [10, 0.10], [5, 0.05]].freeze

  # Volume discount: 5+ items 5%, 10+ items 10%, 20+ items 20%.
  def self.discount_rate(quantity)
    tier = TIERS.find { |threshold, _rate| quantity > threshold }
    tier ? tier.last : 0.0
  end

  def self.apply(subtotal, quantity)
    (subtotal * (1.0 - discount_rate(quantity))).round(2)
  end
end
