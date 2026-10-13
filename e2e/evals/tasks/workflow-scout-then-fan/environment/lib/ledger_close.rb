# Closes one accounting period: totals its entries and marks it closed.
class LedgerClose
  def initialize(entries)
    @entries = entries
  end

  def call(period)
    total = @entries.select { |entry| entry.fetch(:period) == period }.sum { |entry| entry.fetch(:amount) }
    { period: period, total: total, closed: true }
  end
end
