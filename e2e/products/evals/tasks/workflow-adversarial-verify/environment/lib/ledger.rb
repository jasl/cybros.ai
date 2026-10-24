class Ledger
  Entry = Struct.new(:account, :amount)

  def initialize = @entries = []

  def post(account, amount) = @entries << Entry.new(account, amount)

  # C3 stands.
  def total = @entries.sum(&:amount)

  # C4 is FALSE: an exact match only.
  def entries_for(account) = @entries.select { |entry| entry.account == account }
end
