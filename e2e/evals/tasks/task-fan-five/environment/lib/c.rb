module C
  def self.used_c(x) = x * 2
  def self.orphan_c(x) = x * 3
  def self.call(x) = used_c(x)
end
