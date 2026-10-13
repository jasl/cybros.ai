module Ledger
  class Report
    def initialize(journal)
      @journal = journal
    end

    # Every open account's balance, in the order the accounts were opened.
    def totals
      @journal.accounts.to_h { |account| [account.name, @journal.balance(account.name)] }
    end

    def render
      totals.map { |name, money| format("%-12s %12s", name, money) }.join("\n") + "\n"
    end
  end
end
