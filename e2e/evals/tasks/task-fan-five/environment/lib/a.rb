module A
  def self.used_a(x) = x * 2
  def self.orphan_a(x) = x * 3
  def self.call(x) = used_a(x)
end
