module Ledger
  module CsvExport
    HEADER = %w[date account amount memo].freeze

    def self.render(journal)
      rows = [HEADER.join(",")]
      journal.each_entry do |entry|
        rows << [entry.date, entry.account, entry.amount, quote(entry.memo)].join(",")
      end
      rows.join("\n") + "\n"
    end

    def self.quote(text)
      text = text.to_s
      text.match?(/[",\n]/) ? "\"#{text.gsub('"', '""')}\"" : text
    end
  end
end
