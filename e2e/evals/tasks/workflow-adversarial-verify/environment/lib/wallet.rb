class Wallet
  attr_reader :balance

  def initialize(balance = 0) = @balance = balance

  # C1 is FALSE: an overdraft is allowed up to 100.
  def withdraw(amount)
    raise ArgumentError, "overdrawn" if @balance - amount < -100

    @balance -= amount
  end

  # C2 stands.
  def deposit(amount)
    raise ArgumentError, "non-positive" unless amount.positive?

    @balance += amount
  end
end
