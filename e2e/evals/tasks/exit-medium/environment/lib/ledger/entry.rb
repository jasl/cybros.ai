module Ledger
  # One line of the journal: the day, the account it touches, the
  # amount (positive into the account, negative out of it), a memo.
  class Entry
    attr_reader :date, :account, :amount, :memo

    def initialize(date:, account:, amount:, memo: "")
      @date = date
      @account = account
      @amount = amount
      @memo = memo
    end
  end
end
