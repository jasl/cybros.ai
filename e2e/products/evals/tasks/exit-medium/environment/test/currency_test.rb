require "minitest/autorun"
require "ledger"

# The currency feature, as FEATURE.md describes it. Red until it is
# implemented: these tests are the specification.
class CurrencyTest < Minitest::Test
  def entry(date, account, cents, memo = "", **rest)
    Ledger::Entry.new(date: date, account: account, amount: Ledger::Money.new(cents), memo: memo, **rest)
  end

  def journal(rates: nil)
    journal = rates ? Ledger::Journal.new(rates: rates) : Ledger::Journal.new
    journal.open("cash", "asset")
    journal.open("rent", "expense")
    journal
  end

  def rates = Ledger::Rates.new(base: "USD", table: { "EUR" => 1.25 })

  def test_an_entry_is_in_usd_unless_told_otherwise
    assert_equal "USD", entry("2026-01-05", "cash", 1000).currency
    assert_equal "EUR", entry("2026-01-05", "cash", 1000, currency: "EUR").currency
  end

  def test_a_journal_without_rates_refuses_a_second_currency
    ledger = journal
    ledger.post(entry("2026-01-05", "cash", 1000))
    error = assert_raises(Ledger::CurrencyMismatch) { ledger.post(entry("2026-01-06", "cash", 500, currency: "EUR")) }
    assert_match(/EUR/, error.message)
    assert_equal 1, ledger.size, "the refused entry was not posted"
  end

  def test_a_journal_without_rates_keeps_one_foreign_currency_throughout
    ledger = journal
    ledger.post(entry("2026-01-05", "cash", 1000, currency: "EUR"))
    ledger.post(entry("2026-01-06", "cash", 500, currency: "EUR"))
    assert_equal Ledger::Money.new(1500), ledger.balance("cash")
  end

  def test_a_journal_with_rates_states_a_balance_in_its_base
    ledger = journal(rates: rates)
    ledger.post(entry("2026-01-05", "cash", 1000))
    ledger.post(entry("2026-01-06", "cash", 400, currency: "EUR"))
    assert_equal Ledger::Money.new(1500), ledger.balance("cash")
  end

  def test_a_journal_with_rates_still_refuses_a_currency_the_table_lacks
    ledger = journal(rates: rates)
    assert_raises(Ledger::CurrencyMismatch) { ledger.post(entry("2026-01-05", "cash", 100, currency: "GBP")) }
    assert_equal 0, ledger.size
  end

  def test_a_report_totals_by_currency_in_the_original_amounts
    ledger = journal(rates: rates)
    ledger.post(entry("2026-01-05", "cash", 1000))
    ledger.post(entry("2026-01-06", "cash", 400, currency: "EUR"))
    ledger.post(entry("2026-01-07", "rent", 300, currency: "EUR"))
    assert_equal({ "USD" => Ledger::Money.new(1000), "EUR" => Ledger::Money.new(700) },
      Ledger::Report.new(ledger).totals_by_currency)
  end

  def test_the_csv_export_carries_a_currency_column
    ledger = journal(rates: rates)
    ledger.post(entry("2026-01-05", "cash", 1000, "opening"))
    ledger.post(entry("2026-01-06", "cash", 400, "invoice", currency: "EUR"))
    assert_equal ["date,account,amount,currency,memo",
                  "2026-01-05,cash,10.00,USD,opening",
                  "2026-01-06,cash,4.00,EUR,invoice"],
      Ledger::CsvExport.render(ledger).lines.map(&:chomp)
  end
end
