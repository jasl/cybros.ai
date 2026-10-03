module D
  def self.used_d(x) = x * 2
  def self.orphan_d(x) = x * 3
  def self.call(x) = used_d(x)
end
