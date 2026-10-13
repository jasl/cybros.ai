require_relative "ledger"

module Balance
  def self.for(ledger, account)
    postings = ledger.postings.select { |posting| posting.account == account }
    postings.select(&:settled).sum(&:amount)
  end
end
