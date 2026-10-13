module Ledger
  # An amount in integer cents: no floats anywhere near a balance.
  Money = Data.define(:cents) do
    def self.zero = new(0)

    def self.parse(text)
      clean = text.to_s.strip
      whole, fraction = clean.delete_prefix("-").split(".", 2)
      cents = (Integer(whole, 10) * 100) + Integer((fraction.to_s + "00")[0, 2], 10)
      new(clean.start_with?("-") ? -cents : cents)
    end

    def +(other) = with(cents: cents + other.cents)
    def -(other) = with(cents: cents - other.cents)
    def negative? = cents.negative?
    def zero? = cents.zero?

    def to_s
      format("%s%d.%02d", negative? ? "-" : "", cents.abs / 100, cents.abs % 100)
    end
  end
end
