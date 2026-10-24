module B
  def self.used_b(x) = x * 2
  def self.orphan_b(x) = x * 3
  def self.call(x) = used_b(x)
end
