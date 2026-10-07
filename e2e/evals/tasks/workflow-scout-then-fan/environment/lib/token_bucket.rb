# A rate limiter: a request spends tokens that refill at a fixed rate.
class TokenBucket
  def initialize(capacity:, per_second:)
    @capacity = capacity
    @per_second = per_second
    @tokens = capacity
    @at = 0
  end

  def call(now, cost: 1)
    @tokens = [@capacity, @tokens + ((now - @at) * @per_second)].min
    @at = now
    return false if @tokens < cost

    @tokens -= cost
    true
  end
end
