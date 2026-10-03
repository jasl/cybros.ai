require "minitest/autorun"
require "ledger"

class ReportTest < Minitest::Test
  def setup
    @journal = Ledger::Journal.new
    @journal.open("cash", "asset")
    @journal.open("sales", "income")
    @journal.post(Ledger::Entry.new(date: "2026-01-05", account: "cash", amount: Ledger::Money.new(5_000), memo: "opening"))
    @journal.post(Ledger::Entry.new(date: "2026-01-09", account: "sales", amount: Ledger::Money.new(1_250), memo: "invoice, 1"))
    @journal.post(Ledger::Entry.new(date: "2026-01-09", account: "cash", amount: Ledger::Money.new(1_250), memo: "invoice, 1"))
  end

  def test_totals_every_open_account_in_opening_order
    report = Ledger::Report.new(@journal)
    assert_equal({ "cash" => Ledger::Money.new(6_250), "sales" => Ledger::Money.new(1_250) }, report.totals)
    assert_equal "cash                62.50\nsales               12.50\n", report.render
  end

  def test_csv_export_lists_every_entry_under_a_header_and_quotes_a_comma
    csv = Ledger::CsvExport.render(@journal)
    lines = csv.lines.map(&:chomp)
    assert_equal 4, lines.size
    assert_match(/\Adate,account,amount/, lines.first)
    fields = lines[1].split(",")
    assert_equal %w[2026-01-05 cash 50.00], fields.first(3)
    assert_equal "opening", fields.last
    assert_includes lines[2], "\"invoice, 1\""
  end
end
