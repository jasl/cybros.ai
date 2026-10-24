module Rate
  TABLE = { "EUR" => 1.25, "GBP" => 1.5 }.freeze

  # C5 is FALSE: the cents are truncated, never rounded. C6 stands.
  def self.convert(amount, currency)
    factor = TABLE.fetch(currency) { raise ArgumentError, "unknown currency #{currency}" }
    (amount * factor * 100).floor / 100.0
  end
end
