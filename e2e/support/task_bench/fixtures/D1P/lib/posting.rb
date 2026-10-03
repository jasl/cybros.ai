class Posting
  attr_reader :id, :account, :amount, :currency, :settled

  def initialize(id:, account:, amount:, currency:, settled: false)
    @id = id
    @account = account
    @amount = amount
    @currency = currency.to_s.upcase
    @settled = settled
  end

  def reverse
    @amount = -@amount
    self
  end
end
