module Ledger
  class UnknownAccount < Error; end

  # The book: accounts are opened by name, entries are posted to open
  # accounts, and a balance is the sum of an account's entries.
  class Journal
    def initialize
      @accounts = {}
      @entries = []
    end

    def open(name, kind)
      @accounts[name] = Account.new(name, kind)
    end

    def account(name)
      @accounts.fetch(name) { raise UnknownAccount, "no account #{name.inspect} is open" }
    end

    def post(entry)
      account(entry.account)
      @entries << entry
      entry
    end

    def entries_for(name) = @entries.select { |entry| entry.account == name }

    def balance(name) = entries_for(name).map(&:amount).reduce(Money.zero, :+)

    def each_entry(&) = @entries.each(&)

    def accounts = @accounts.values

    def size = @entries.size
  end
end
