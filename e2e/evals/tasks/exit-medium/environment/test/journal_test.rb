require "minitest/autorun"
require "ledger"

class JournalTest < Minitest::Test
  def setup
    @journal = Ledger::Journal.new
    @journal.open("cash", "asset")
    @journal.open("rent", "expense")
  end

  def entry(date, account, cents, memo = "")
    Ledger::Entry.new(date: date, account: account, amount: Ledger::Money.new(cents), memo: memo)
  end

  def test_posts_entries_and_balances_an_account
    @journal.post(entry("2026-01-05", "cash", 10_000, "opening"))
    @journal.post(entry("2026-01-06", "cash", -3_000, "rent"))
    @journal.post(entry("2026-01-06", "rent", 3_000, "rent"))
    assert_equal Ledger::Money.new(7_000), @journal.balance("cash")
    assert_equal Ledger::Money.new(3_000), @journal.balance("rent")
    assert_equal 2, @journal.entries_for("cash").size
  end

  def test_refuses_an_entry_on_an_account_that_is_not_open
    assert_raises(Ledger::UnknownAccount) { @journal.post(entry("2026-01-05", "petty", 100)) }
    assert_equal 0, @journal.size
  end

  def test_an_account_kind_must_be_known
    assert_raises(Ledger::Error) { @journal.open("void", "mystery") }
  end
end
