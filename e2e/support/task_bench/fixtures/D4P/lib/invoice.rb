class Invoice
  def initialize(attributes = {})
    @attributes = attributes
  end

  def to_h = @attributes.dup
end
