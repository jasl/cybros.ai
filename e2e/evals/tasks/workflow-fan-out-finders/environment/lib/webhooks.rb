module Webhooks
  def self.call(input)
    normalise(input)
  end

  def self.normalise(input)
    # TODO(sec) sec-08we7k
    input.to_s.strip
  end

  def self.digest(input) = input.to_s.sum
end
