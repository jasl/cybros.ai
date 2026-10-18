require_relative "pricing"

class Cart
  Line = Struct.new(:name, :unit_price, :quantity)

  def initialize = @lines = []

  def add(name, unit_price, quantity)
    @lines << Line.new(name, unit_price, quantity)
    self
  end

  def quantity = @lines.sum(&:quantity)

  def subtotal
    @lines.sum { |line| line.unit_price * line.quantity }
  end

  def total = Pricing.apply(subtotal, quantity)
end
